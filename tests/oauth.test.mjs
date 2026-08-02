import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const s256 = (value) =>
  createHash("sha256").update(value).digest("base64url");
const randomString = () => randomBytes(24).toString("base64url");

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve());
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createHttpServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// --- fake upstream GitLab: OAuth endpoints + API, zero external access ---
const gitlabPort = await freePort();
const upstream = {
  authorizeRequests: [],
  tokenRequests: [],
  apiRequests: [],
  challenges: new Map(),
};
const fakeGitlab = createHttpServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${gitlabPort}`);

  if (url.pathname === "/oauth/authorize") {
    const query = Object.fromEntries(url.searchParams);
    upstream.authorizeRequests.push(query);
    upstream.challenges.set("gitlab-auth-code", query.code_challenge);
    res.writeHead(302, {
      location: `${query.redirect_uri}?code=gitlab-auth-code&state=${encodeURIComponent(query.state)}`,
    });
    res.end();
    return;
  }

  if (url.pathname === "/oauth/token") {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const form = Object.fromEntries(
        new URLSearchParams(Buffer.concat(chunks).toString("utf8")),
      );
      upstream.tokenRequests.push(form);
      const fail = (status, error) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify({ error }));
      };
      if (form.client_secret !== "test-app-secret") {
        fail(401, "invalid_client");
        return;
      }
      if (form.grant_type === "authorization_code") {
        if (
          form.code !== "gitlab-auth-code" ||
          s256(form.code_verifier ?? "") !== upstream.challenges.get(form.code)
        ) {
          fail(400, "invalid_grant");
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            access_token: "gl-oauth-access-1",
            refresh_token: "gl-refresh-1",
            token_type: "Bearer",
            expires_in: 7200,
            scope: "api",
          }),
        );
        return;
      }
      if (form.grant_type === "refresh_token") {
        if (form.refresh_token !== "gl-refresh-1") {
          fail(400, "invalid_grant");
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            access_token: "gl-oauth-access-2",
            refresh_token: "gl-refresh-2",
            token_type: "Bearer",
            expires_in: 7200,
            scope: "api",
          }),
        );
        return;
      }
      fail(400, "unsupported_grant_type");
    });
    return;
  }

  if (url.pathname.startsWith("/api/v4/")) {
    upstream.apiRequests.push({
      path: `${url.pathname}${url.search}`,
      authorization: req.headers.authorization,
      privateToken: req.headers["private-token"],
    });
    const accepted = new Set([
      "Bearer gl-oauth-access-1",
      "Bearer gl-oauth-access-2",
    ]);
    if (!accepted.has(req.headers.authorization)) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ message: "401 Unauthorized" }));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end("[]");
    return;
  }

  res.writeHead(404);
  res.end();
});
await listen(fakeGitlab, gitlabPort);

// --- server under test, with the OAuth broker enabled ---
process.env.GitLabApiUrl = `http://127.0.0.1:${gitlabPort}/api/v4`;
const { MCP_PATH, startHttpServer } = await import("../src/server.mjs");

const mcpPort = await freePort();
const publicUrl = `http://127.0.0.1:${mcpPort}`;
const storeDir = mkdtempSync(join(tmpdir(), "gitlab-mcp-oauth-"));
const storePath = join(storeDir, "clients.json");
const oauthConfig = {
  publicUrl,
  clientId: "test-app-id",
  clientSecret: "test-app-secret",
  gitlabBaseUrl: `http://127.0.0.1:${gitlabPort}`,
  storePath,
};
const { httpServer } = await startHttpServer({
  host: "127.0.0.1",
  port: mcpPort,
  oauth: oauthConfig,
});

const clientRedirectUri = "http://127.0.0.1:54321/callback";

async function readJson(response) {
  return JSON.parse(await response.text());
}

// full downstream OAuth dance; returns the token response body
async function runAuthorizationFlow({ clientId, verifier }) {
  const challenge = s256(verifier);
  const state = randomString();
  const authorize = await fetch(
    `${publicUrl}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: clientId,
        redirect_uri: clientRedirectUri,
        state,
        code_challenge: challenge,
        code_challenge_method: "S256",
      }),
    { redirect: "manual" },
  );
  assert.equal(authorize.status, 302);
  const gitlabUrl = authorize.headers.get("location");
  assert.ok(gitlabUrl.startsWith(`http://127.0.0.1:${gitlabPort}/oauth/authorize?`));

  const gitlabRedirect = await fetch(gitlabUrl, { redirect: "manual" });
  assert.equal(gitlabRedirect.status, 302);
  const callbackUrl = gitlabRedirect.headers.get("location");
  assert.ok(callbackUrl.startsWith(`${publicUrl}/oauth/callback?`));

  const callback = await fetch(callbackUrl, { redirect: "manual" });
  assert.equal(callback.status, 302);
  const clientUrl = new URL(callback.headers.get("location"));
  assert.equal(
    `${clientUrl.origin}${clientUrl.pathname}`,
    clientRedirectUri,
  );
  assert.equal(clientUrl.searchParams.get("state"), state);
  const code = clientUrl.searchParams.get("code");
  assert.ok(code);

  const tokenResponse = await fetch(`${publicUrl}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: clientRedirectUri,
      code_verifier: verifier,
    }),
  });
  return tokenResponse;
}

try {
  // --- well-known metadata ---
  const protectedResource = await readJson(
    await fetch(`${publicUrl}/.well-known/oauth-protected-resource`),
  );
  assert.equal(protectedResource.resource, `${publicUrl}${MCP_PATH}`);
  assert.deepEqual(protectedResource.authorization_servers, [publicUrl]);
  assert.deepEqual(protectedResource.bearer_methods_supported, ["header"]);

  const asMetadata = await readJson(
    await fetch(`${publicUrl}/.well-known/oauth-authorization-server`),
  );
  assert.equal(asMetadata.issuer, publicUrl);
  assert.equal(asMetadata.authorization_endpoint, `${publicUrl}/oauth/authorize`);
  assert.equal(asMetadata.token_endpoint, `${publicUrl}/oauth/token`);
  assert.equal(asMetadata.registration_endpoint, `${publicUrl}/oauth/register`);
  assert.deepEqual(asMetadata.code_challenge_methods_supported, ["S256"]);

  // --- DCR validation ---
  const evilRedirect = await fetch(`${publicUrl}/oauth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ redirect_uris: ["https://evil.example/callback"] }),
  });
  assert.equal(evilRedirect.status, 400);

  const secretClient = await fetch(`${publicUrl}/oauth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      redirect_uris: [clientRedirectUri],
      token_endpoint_auth_method: "client_secret_basic",
    }),
  });
  assert.equal(secretClient.status, 400);

  const registered = await fetch(`${publicUrl}/oauth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "test client",
      redirect_uris: [clientRedirectUri],
    }),
  });
  assert.equal(registered.status, 201);
  const registration = await readJson(registered);
  assert.ok(registration.client_id);
  assert.equal(registration.token_endpoint_auth_method, "none");

  const persisted = JSON.parse(readFileSync(storePath, "utf8"));
  assert.equal(persisted.clients.length, 1);
  assert.equal(persisted.clients[0].client_id, registration.client_id);

  // --- authorize validation ---
  const unknownClient = await fetch(
    `${publicUrl}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: "00000000-0000-0000-0000-000000000000",
        redirect_uri: clientRedirectUri,
        state: "s",
        code_challenge: s256("v"),
        code_challenge_method: "S256",
      }),
    { redirect: "manual" },
  );
  assert.equal(unknownClient.status, 400);

  const wrongRedirect = await fetch(
    `${publicUrl}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: registration.client_id,
        redirect_uri: "http://127.0.0.1:9999/other",
        state: "s",
        code_challenge: s256("v"),
        code_challenge_method: "S256",
      }),
    { redirect: "manual" },
  );
  assert.equal(wrongRedirect.status, 400);

  const noPkce = await fetch(
    `${publicUrl}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: registration.client_id,
        redirect_uri: clientRedirectUri,
        state: "s",
      }),
    { redirect: "manual" },
  );
  assert.equal(noPkce.status, 400);

  // --- happy path: full authorization code + PKCE flow ---
  const verifier = randomString();
  const tokenResponse = await runAuthorizationFlow({
    clientId: registration.client_id,
    verifier,
  });
  assert.equal(tokenResponse.status, 200);
  const tokens = await readJson(tokenResponse);
  assert.equal(tokens.access_token, "gl-oauth-access-1");
  assert.equal(tokens.refresh_token, "gl-refresh-1");

  // the broker ran its own PKCE against the upstream GitLab
  assert.equal(upstream.authorizeRequests.length, 1);
  assert.equal(
    upstream.authorizeRequests[0].client_id,
    "test-app-id",
  );
  assert.equal(
    upstream.authorizeRequests[0].redirect_uri,
    `${publicUrl}/oauth/callback`,
  );
  assert.equal(upstream.tokenRequests[0].client_secret, "test-app-secret");
  assert.ok(upstream.tokenRequests[0].code_verifier);

  // --- codes are single-use and verifier-bound ---
  const reusedCode = await fetch(`${publicUrl}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: "already-consumed",
      client_id: registration.client_id,
      redirect_uri: clientRedirectUri,
      code_verifier: verifier,
    }),
  });
  assert.equal(reusedCode.status, 400);

  const secondVerifier = randomString();
  const secondFlow = await runAuthorizationFlow({
    clientId: registration.client_id,
    verifier: secondVerifier,
  });
  assert.equal(secondFlow.status, 200);

  const wrongVerifierFlow = await runAuthorizationFlow({
    clientId: registration.client_id,
    verifier: randomString(),
  });
  // third flow: exchange with a mismatched verifier must fail
  const thirdVerifier = randomString();
  const thirdChallenge = s256(thirdVerifier);
  const thirdAuthorize = await fetch(
    `${publicUrl}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: registration.client_id,
        redirect_uri: clientRedirectUri,
        state: randomString(),
        code_challenge: thirdChallenge,
        code_challenge_method: "S256",
      }),
    { redirect: "manual" },
  );
  const thirdGitlab = await fetch(thirdAuthorize.headers.get("location"), {
    redirect: "manual",
  });
  const thirdCallback = await fetch(thirdGitlab.headers.get("location"), {
    redirect: "manual",
  });
  const thirdCode = new URL(thirdCallback.headers.get("location")).searchParams.get("code");
  const mismatched = await fetch(`${publicUrl}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: thirdCode,
      client_id: registration.client_id,
      redirect_uri: clientRedirectUri,
      code_verifier: randomString(),
    }),
  });
  assert.equal(mismatched.status, 400);

  // --- refresh token grant relays upstream ---
  const refreshed = await fetch(`${publicUrl}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: "gl-refresh-1",
      client_id: registration.client_id,
    }),
  });
  assert.equal(refreshed.status, 200);
  const refreshedTokens = await readJson(refreshed);
  assert.equal(refreshedTokens.access_token, "gl-oauth-access-2");

  // --- OAuth access token works against the GitLab MCP route and is forwarded as Bearer ---
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { StreamableHTTPClientTransport } = await import(
    "@modelcontextprotocol/sdk/client/streamableHttp.js"
  );
  const mcpClient = new Client({ name: "oauth-test", version: "1.0.0" });
  await mcpClient.connect(
    new StreamableHTTPClientTransport(new URL(`${publicUrl}${MCP_PATH}`), {
      requestInit: {
        headers: { Authorization: "Bearer gl-oauth-access-1" },
      },
    }),
  );
  const { tools } = await mcpClient.listTools();
  assert.deepEqual(
    tools.map(({ name }) => name),
    [
      "configure_project_scope",
      "list_group_projects",
      "list_pipelines",
      "list_pipeline_jobs",
      "play_deploy_job",
    ],
  );
  const unconfigured = await mcpClient.callTool({
    name: "list_pipelines",
    arguments: {
      scope_token: "00000000-0000-4000-8000-000000000000",
      project_path: "team/example/one",
    },
  });
  assert.equal(unconfigured.isError, true);
  assert.match(unconfigured.content[0].text, /confirm repositories first/);

  const configured = await mcpClient.callTool({
    name: "configure_project_scope",
    arguments: {
      project_paths: ["team/example/one"],
      confirmation: "CONFIRM PROJECT SCOPE",
    },
  });
  const { scope_token: scopeToken } = JSON.parse(configured.content[0].text);
  const outsideScope = await mcpClient.callTool({
    name: "list_pipelines",
    arguments: {
      scope_token: scopeToken,
      project_path: "team/example/two",
    },
  });
  assert.equal(outsideScope.isError, true);
  assert.match(outsideScope.content[0].text, /confirmed project scope/);

  const listed = await mcpClient.callTool({
    name: "list_group_projects",
    arguments: { group_path: "team" },
  });
  assert.notEqual(listed.isError, true);
  const forwarded = upstream.apiRequests.find((entry) =>
    entry.path.startsWith("/api/v4/groups/team/projects"),
  );
  assert.ok(forwarded);
  assert.equal(forwarded.authorization, "Bearer gl-oauth-access-1");
  assert.equal(forwarded.privateToken, undefined);
  await mcpClient.close();

  // --- a bearer value not issued by the OAuth broker is rejected at the GitLab MCP route ---
  const unknownBearer = await fetch(`${publicUrl}${MCP_PATH}`, {
    method: "POST",
    headers: {
      authorization: "Bearer manually-supplied-access-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
  });
  assert.equal(unknownBearer.status, 401);

  // --- 401 advertises the protected-resource metadata for discovery ---
  const unauthorized = await fetch(`${publicUrl}${MCP_PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
  });
  assert.equal(unauthorized.status, 401);
  const authenticate = unauthorized.headers.get("www-authenticate");
  assert.ok(
    authenticate.includes(
      `resource_metadata="${publicUrl}/.well-known/oauth-protected-resource"`,
    ),
  );

  // --- registrations survive a restart (persistence) ---
  const secondPort = await freePort();
  const { httpServer: secondServer } = await startHttpServer({
    host: "127.0.0.1",
    port: secondPort,
    oauth: { ...oauthConfig, publicUrl: `http://127.0.0.1:${secondPort}` },
  });
  const afterRestart = await fetch(
    `http://127.0.0.1:${secondPort}/oauth/authorize?` +
      new URLSearchParams({
        response_type: "code",
        client_id: registration.client_id,
        redirect_uri: clientRedirectUri,
        state: randomString(),
        code_challenge: s256(randomString()),
        code_challenge_method: "S256",
      }),
    { redirect: "manual" },
  );
  assert.equal(afterRestart.status, 302);
  secondServer.close();

  // --- every HTTP server requires the OAuth broker ---
  const plainPort = await freePort();
  assert.throws(
    () => startHttpServer({ host: "127.0.0.1", port: plainPort }),
    /OAuth broker configuration is required/,
  );

  console.log("ok: OAuth broker flow verified end to end");
} finally {
  httpServer.close();
  fakeGitlab.close();
  rmSync(storeDir, { recursive: true, force: true });
}
