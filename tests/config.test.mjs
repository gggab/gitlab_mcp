import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: ["../src/server.mjs"],
  cwd: import.meta.dirname,
  env: {
    ...process.env,
    GitLabAccessToken: "not-used",
  },
});
const client = new Client({ name: "gitlab-mcp-config", version: "1.0.0" });

try {
  await client.connect(transport);
  const { tools } = await client.listTools();

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
  assert.equal(tools[0].annotations.readOnlyHint, false);
  assert.equal(tools[1].annotations.readOnlyHint, true);
  assert.ok(
    tools.find(({ name }) => name === "play_deploy_job").inputSchema.properties
      .deploy_job_name,
  );

  const unconfigured = await client.callTool({
    name: "list_pipelines",
    arguments: {
      scope_token: "00000000-0000-4000-8000-000000000000",
      project_path: "team/example/one",
    },
  });
  assert.equal(unconfigured.isError, true);
  assert.match(unconfigured.content[0].text, /confirm repositories first/);

  const configured = await client.callTool({
    name: "configure_project_scope",
    arguments: {
      project_paths: ["team/example/one", "team/example/two"],
      confirmation: "CONFIRM PROJECT SCOPE",
    },
  });
  const scope = JSON.parse(configured.content[0].text);
  assert.match(scope.scope_token, /^[0-9a-f-]{36}$/);
  assert.deepEqual(scope.project_paths, [
    "team/example/one",
    "team/example/two",
  ]);

  const rejected = await client.callTool({
    name: "list_pipelines",
    arguments: {
      scope_token: scope.scope_token,
      project_path: "team/example/other",
    },
  });
  assert.equal(rejected.isError, true);
  assert.match(rejected.content[0].text, /confirmed project scope/);

  const reconfigured = await client.callTool({
    name: "configure_project_scope",
    arguments: {
      project_paths: ["team/other/three"],
      confirmation: "CONFIRM PROJECT SCOPE",
    },
  });
  const newScope = JSON.parse(reconfigured.content[0].text);
  assert.notEqual(newScope.scope_token, scope.scope_token);
  const oldProjectRejected = await client.callTool({
    name: "list_pipelines",
    arguments: {
      scope_token: newScope.scope_token,
      project_path: "team/example/one",
    },
  });
  assert.equal(oldProjectRejected.isError, true);

  console.log("ok: conversation project scope verified");
} finally {
  await client.close();
}
