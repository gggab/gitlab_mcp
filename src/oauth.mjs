import { createHash, randomBytes, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

// OAuth broker: lets MCP clients (Kimi, Codex) authenticate with their GitLab
// account in the browser. Downstream the broker is a
// standards-compliant authorization server (DCR + authorization code + PKCE);
// upstream it is a single pre-registered confidential GitLab OAuth app whose
// fixed callback URI absorbs GitLab's exact redirect-URI matching. The token
// endpoint relays the GitLab-issued tokens to the client, so the broker keeps
// no persistent token state and MCP requests keep forwarding Bearer tokens.
//
// Enabled only when server.mjs passes a config; without one the broker does
// is required by the HTTP server.

const PENDING_TTL_MS = 10 * 60 * 1000;
const LOCAL_REDIRECT_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const SUPPORTED_GRANTS = new Set(["authorization_code", "refresh_token"]);

const randomString = () => randomBytes(32).toString("base64url");
const s256 = (value) => createHash("sha256").update(value).digest("base64url");

function sendJson(res, status, body, headers = {}) {
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
    ...headers,
  });
  res.end(JSON.stringify(body));
}

function sendRedirect(res, location) {
  res.writeHead(302, { location, "cache-control": "no-store" });
  res.end();
}

function oauthError(res, status, error, description) {
  sendJson(res, status, { error, error_description: description });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("error", reject);
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

function isLoopbackRedirect(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  return (
    parsed.protocol === "http:" &&
    LOCAL_REDIRECT_HOSTS.has(parsed.hostname)
  );
}

export function createOAuthBroker({
  publicUrl,
  clientId,
  clientSecret,
  gitlabBaseUrl,
  storePath,
  mcpPath,
}) {
  const issuer = publicUrl.replace(/\/+$/, "");
  const upstreamBase = gitlabBaseUrl.replace(/\/+$/, "");
  const callbackUrl = `${issuer}/oauth/callback`;
  const resourceUrl = `${issuer}${mcpPath}`;
  const resourceMetadataUrl = `${issuer}/.well-known/oauth-protected-resource`;

  const clients = new Map();
  const pendingAuthorizations = new Map();
  const downstreamCodes = new Map();
  // ponytail: token hashes are process-local, so clients reauthorize after a restart; persist only if that becomes a support burden.
  const issuedAccessTokens = new Map();

  if (storePath && existsSync(storePath)) {
    const stored = JSON.parse(readFileSync(storePath, "utf8"));
    for (const record of stored.clients ?? []) {
      clients.set(record.client_id, record);
    }
  }

  function persistClients() {
    if (!storePath) {
      return;
    }
    const temporary = `${storePath}.tmp`;
    writeFileSync(
      temporary,
      JSON.stringify({ clients: [...clients.values()] }, null, 2),
      "utf8",
    );
    renameSync(temporary, storePath);
  }

  function sweepExpired() {
    const now = Date.now();
    for (const [key, entry] of pendingAuthorizations) {
      if (entry.expiresAt <= now) {
        pendingAuthorizations.delete(key);
      }
    }
    for (const [key, entry] of downstreamCodes) {
      if (entry.expiresAt <= now) {
        downstreamCodes.delete(key);
      }
    }
    for (const [key, expiresAt] of issuedAccessTokens) {
      if (expiresAt <= now) {
        issuedAccessTokens.delete(key);
      }
    }
  }

  function rememberAccessToken(tokens) {
    const accessToken = tokens?.access_token;
    const expiresIn = Number(tokens?.expires_in);
    if (
      typeof accessToken !== "string" ||
      !accessToken ||
      !Number.isFinite(expiresIn) ||
      expiresIn <= 0
    ) {
      throw new Error("GitLab OAuth token response is missing access_token or expires_in");
    }
    issuedAccessTokens.set(
      createHash("sha256").update(accessToken).digest("base64url"),
      Date.now() + expiresIn * 1000,
    );
  }

  async function upstreamTokenRequest(form) {
    const response = await fetch(`${upstreamBase}/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        ...form,
      }),
      signal: AbortSignal.timeout(30_000),
    });
    const body = await response.text();
    if (!response.ok) {
      throw new Error(
        `GitLab token endpoint ${response.status}: ${body.slice(0, 300)}`,
      );
    }
    return JSON.parse(body);
  }

  async function handleRegister(req, res) {
    let metadata;
    try {
      metadata = JSON.parse(await readBody(req));
    } catch {
      oauthError(res, 400, "invalid_client_metadata", "Body must be JSON");
      return;
    }

    const redirectUris = metadata?.redirect_uris;
    if (
      !Array.isArray(redirectUris) ||
      redirectUris.length === 0 ||
      !redirectUris.every((uri) => typeof uri === "string")
    ) {
      oauthError(res, 400, "invalid_redirect_uri", "redirect_uris is required");
      return;
    }
    if (!redirectUris.every(isLoopbackRedirect)) {
      oauthError(
        res,
        400,
        "invalid_redirect_uri",
        "redirect_uris must be http loopback addresses (localhost, 127.0.0.1, [::1])",
      );
      return;
    }

    const grantTypes = metadata.grant_types ?? ["authorization_code"];
    if (
      !Array.isArray(grantTypes) ||
      !grantTypes.includes("authorization_code") ||
      !grantTypes.every((grant) => SUPPORTED_GRANTS.has(grant))
    ) {
      oauthError(
        res,
        400,
        "invalid_client_metadata",
        "grant_types must include authorization_code and only use supported grants",
      );
      return;
    }

    const responseTypes = metadata.response_types ?? ["code"];
    if (
      !Array.isArray(responseTypes) ||
      responseTypes.length !== 1 ||
      responseTypes[0] !== "code"
    ) {
      oauthError(
        res,
        400,
        "invalid_client_metadata",
        'response_types must be ["code"]',
      );
      return;
    }

    if (
      metadata.token_endpoint_auth_method !== undefined &&
      metadata.token_endpoint_auth_method !== "none"
    ) {
      oauthError(
        res,
        400,
        "invalid_client_metadata",
        "Only public clients (token_endpoint_auth_method = none) are accepted",
      );
      return;
    }

    const record = {
      client_id: randomUUID(),
      client_name:
        typeof metadata.client_name === "string"
          ? metadata.client_name.slice(0, 200)
          : undefined,
      redirect_uris: redirectUris,
      grant_types: grantTypes,
    };
    clients.set(record.client_id, record);
    persistClients();

    sendJson(
      res,
      201,
      {
        client_id: record.client_id,
        client_name: record.client_name,
        redirect_uris: record.redirect_uris,
        grant_types: record.grant_types,
        response_types: ["code"],
        token_endpoint_auth_method: "none",
        client_id_issued_at: Math.floor(Date.now() / 1000),
      },
    );
  }

  function handleAuthorize(res, query) {
    if (query.response_type !== "code") {
      oauthError(res, 400, "invalid_request", "response_type must be code");
      return;
    }
    const client = clients.get(query.client_id ?? "");
    if (!client) {
      oauthError(res, 400, "invalid_client", "Unknown client_id");
      return;
    }
    if (!client.redirect_uris.includes(query.redirect_uri ?? "")) {
      oauthError(
        res,
        400,
        "invalid_request",
        "redirect_uri does not match the registered value",
      );
      return;
    }
    if (!query.state) {
      oauthError(res, 400, "invalid_request", "state is required");
      return;
    }
    if (!query.code_challenge || query.code_challenge_method !== "S256") {
      oauthError(
        res,
        400,
        "invalid_request",
        "PKCE with S256 code_challenge is required",
      );
      return;
    }

    sweepExpired();
    const upstreamState = randomString();
    const verifier = randomString();
    pendingAuthorizations.set(upstreamState, {
      clientId: client.client_id,
      redirectUri: query.redirect_uri,
      clientState: query.state,
      codeChallenge: query.code_challenge,
      verifier,
      expiresAt: Date.now() + PENDING_TTL_MS,
    });

    sendRedirect(
      res,
      `${upstreamBase}/oauth/authorize?` +
        new URLSearchParams({
          client_id: clientId,
          redirect_uri: callbackUrl,
          response_type: "code",
          scope: "api",
          state: upstreamState,
          code_challenge: s256(verifier),
          code_challenge_method: "S256",
        }),
    );
  }

  async function handleCallback(res, query) {
    if (query.error) {
      oauthError(
        res,
        400,
        "access_denied",
        `GitLab authorization failed: ${query.error}`,
      );
      return;
    }
    const pending = pendingAuthorizations.get(query.state ?? "");
    if (!pending) {
      oauthError(
        res,
        400,
        "invalid_request",
        "Unknown or expired authorization state",
      );
      return;
    }
    pendingAuthorizations.delete(query.state);

    let tokens;
    try {
      tokens = await upstreamTokenRequest({
        grant_type: "authorization_code",
        code: query.code ?? "",
        redirect_uri: callbackUrl,
        code_verifier: pending.verifier,
      });
      rememberAccessToken(tokens);
    } catch (error) {
      oauthError(res, 502, "server_error", error.message);
      return;
    }

    const downstreamCode = randomString();
    downstreamCodes.set(downstreamCode, {
      tokens,
      clientId: pending.clientId,
      redirectUri: pending.redirectUri,
      codeChallenge: pending.codeChallenge,
      expiresAt: Date.now() + PENDING_TTL_MS,
    });

    const target = new URL(pending.redirectUri);
    target.searchParams.set("code", downstreamCode);
    target.searchParams.set("state", pending.clientState);
    sendRedirect(res, target.toString());
  }

  async function handleToken(req, res) {
    const form = Object.fromEntries(new URLSearchParams(await readBody(req)));

    if (form.grant_type === "authorization_code") {
      const code = downstreamCodes.get(form.code ?? "");
      if (!code) {
        oauthError(res, 400, "invalid_grant", "Unknown or expired code");
        return;
      }
      downstreamCodes.delete(form.code);
      if (
        code.clientId !== form.client_id ||
        code.redirectUri !== form.redirect_uri ||
        s256(form.code_verifier ?? "") !== code.codeChallenge
      ) {
        oauthError(
          res,
          400,
          "invalid_grant",
          "client_id, redirect_uri, and PKCE verifier must match the authorization request",
        );
        return;
      }
      sendJson(res, 200, code.tokens);
      return;
    }

    if (form.grant_type === "refresh_token") {
      if (!form.refresh_token) {
        oauthError(res, 400, "invalid_request", "refresh_token is required");
        return;
      }
      try {
        const tokens = await upstreamTokenRequest({
          grant_type: "refresh_token",
          refresh_token: form.refresh_token,
        });
        rememberAccessToken(tokens);
        sendJson(res, 200, tokens);
      } catch (error) {
        oauthError(res, 400, "invalid_grant", error.message);
      }
      return;
    }

    oauthError(
      res,
      400,
      "unsupported_grant_type",
      "Supported grants: authorization_code, refresh_token",
    );
  }

  return {
    resourceMetadataUrl,

    hasIssuedAccessToken(accessToken) {
      sweepExpired();
      return issuedAccessTokens.has(
        createHash("sha256").update(accessToken).digest("base64url"),
      );
    },

    async handleRequest(req, res, url) {
      const query = Object.fromEntries(url.searchParams);
      switch (url.pathname) {
        case "/.well-known/oauth-protected-resource":
          sendJson(res, 200, {
            resource: resourceUrl,
            authorization_servers: [issuer],
            bearer_methods_supported: ["header"],
            scopes_supported: ["api"],
            resource_name: "GitLab Deployment MCP",
          });
          return true;
        case "/.well-known/oauth-authorization-server":
          sendJson(res, 200, {
            issuer,
            authorization_endpoint: `${issuer}/oauth/authorize`,
            token_endpoint: `${issuer}/oauth/token`,
            registration_endpoint: `${issuer}/oauth/register`,
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", "refresh_token"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
            scopes_supported: ["api"],
            require_state_parameter: true,
          });
          return true;
        case "/oauth/register":
          if (req.method !== "POST") return false;
          await handleRegister(req, res);
          return true;
        case "/oauth/authorize":
          if (req.method !== "GET") return false;
          handleAuthorize(res, query);
          return true;
        case "/oauth/callback":
          if (req.method !== "GET") return false;
          await handleCallback(res, query);
          return true;
        case "/oauth/token":
          if (req.method !== "POST") return false;
          await handleToken(req, res);
          return true;
        default:
          return false;
      }
    },
  };
}
