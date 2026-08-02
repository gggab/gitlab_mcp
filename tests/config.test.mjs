import assert from "node:assert/strict";
import { MCP_PATH, startHttpServer } from "../src/server.mjs";

assert.throws(
  () => startHttpServer({ port: 0 }),
  /OAuth broker configuration is required/,
);

const { httpServer, host, port } = await startHttpServer({
  port: 0,
  oauth: {
    publicUrl: "https://mcp.example.test",
    clientId: "test-client-id",
    clientSecret: "test-client-secret",
    gitlabBaseUrl: "https://gitlab.example.test",
  },
});

try {
  const bareMcp = await fetch(`http://${host}:${port}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
  });
  assert.equal(bareMcp.status, 404);

  const unauthorized = await fetch(`http://${host}:${port}${MCP_PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {},
    }),
  });
  assert.equal(unauthorized.status, 401);
  assert.match(
    unauthorized.headers.get("www-authenticate"),
    /resource_metadata="https:\/\/mcp\.example\.test\/.well-known\/oauth-protected-resource"/,
  );

  console.log("ok: OAuth-protected streamable HTTP configuration verified");
} finally {
  httpServer.close();
}
