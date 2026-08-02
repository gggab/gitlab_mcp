import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";

const gitlab = createServer((req, res) => {
  assert.equal(req.headers.authorization, "Bearer personal-token");
  assert.match(req.url, /^\/api\/v4\/groups\/team\/projects/);
  res.writeHead(200, { "content-type": "application/json" });
  res.end("[]");
});
gitlab.listen(0, "127.0.0.1");
await once(gitlab, "listening");
const gitlabPort = gitlab.address().port;
process.env.GitLabApiUrl = `http://127.0.0.1:${gitlabPort}/api/v4`;

const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
const { StreamableHTTPClientTransport } = await import(
  "@modelcontextprotocol/sdk/client/streamableHttp.js"
);
const { MCP_PATH, serverConfigFromEnv, startHttpServer } = await import("../src/server.mjs");

const saved = Object.fromEntries(
  ["GitLabMcpAuthMode", "GitLabMcpPublicUrl", "GitLabOAuthClientId", "GitLabOAuthClientSecret", "GitLabOAuthStorePath"].map((name) => [name, process.env[name]]),
);
try {
  process.env.GitLabMcpAuthMode = "personal-token";
  for (const name of Object.keys(saved).filter((name) => name !== "GitLabMcpAuthMode")) delete process.env[name];
  assert.deepEqual(serverConfigFromEnv(), { authMode: "personal-token" });

  const { httpServer, host, port } = await startHttpServer({ port: 0, authMode: "personal-token" });
  try {
    const baseUrl = `http://${host}:${port}`;
    const unauthorized = await fetch(`${baseUrl}${MCP_PATH}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
    });
    assert.equal(unauthorized.status, 401);
    assert.equal(unauthorized.headers.get("www-authenticate"), null);

    const client = new Client({ name: "personal-token-test", version: "1.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`${baseUrl}${MCP_PATH}`), {
        requestInit: { headers: { Authorization: "Bearer personal-token" } },
      }),
    );
    const result = await client.callTool({ name: "list_group_projects", arguments: { group_path: "team" } });
    assert.notEqual(result.isError, true);
    await client.close();
  } finally {
    httpServer.close();
  }

  process.env.GitLabOAuthClientId = "leftover";
  assert.throws(() => serverConfigFromEnv(), /cannot use OAuth configuration/);
  console.log("ok: personal-token HTTP configuration verified");
} finally {
  for (const [name, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  gitlab.close();
}
