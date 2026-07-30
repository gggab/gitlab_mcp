import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { MCP_PATH, startHttpServer } from "../src/server.mjs";

function config(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required for the live smoke test`);
  return value;
}

const projectPath = config("GitLabSmokeProjectPath");
const deployJobName = config("GitLabSmokeDeployJobName");
const pipelineRef = process.env.GitLabSmokeRef?.trim();
config("GitLabAccessToken");
const { httpServer, host, port } = await startHttpServer({ port: 0 });
const transport = new StreamableHTTPClientTransport(
  new URL(`http://${host}:${port}${MCP_PATH}`),
);
const client = new Client({ name: "gitlab-mcp-smoke", version: "1.0.0" });

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
  assert.equal(
    tools.find(({ name }) => name === "play_deploy_job").annotations
      .readOnlyHint,
    false,
  );
  const configured = await client.callTool({
    name: "configure_project_scope",
    arguments: {
      project_paths: [projectPath],
      confirmation: "CONFIRM PROJECT SCOPE",
    },
  });
  const { scope_token: scopeToken } = JSON.parse(configured.content[0].text);

  const result = await client.callTool({
    name: "list_group_projects",
    arguments: {
      group_path: projectPath.slice(0, projectPath.lastIndexOf("/")),
      search: projectPath.split("/").at(-1),
    },
  });
  const projects = JSON.parse(result.content[0].text);
  assert.ok(
    projects.some(
      ({ path_with_namespace }) => path_with_namespace === projectPath,
    ),
  );

  const pipelineResult = await client.callTool({
    name: "list_pipelines",
    arguments: {
      project_path: projectPath,
      scope_token: scopeToken,
      ...(pipelineRef ? { ref: pipelineRef } : {}),
      limit: 50,
    },
  });
  const pipelines = JSON.parse(pipelineResult.content[0].text);
  assert.ok(pipelines.length > 0);

  let deployJob;
  for (const pipeline of pipelines) {
    const jobResult = await client.callTool({
      name: "list_pipeline_jobs",
      arguments: {
        project_path: projectPath,
        pipeline_id: pipeline.id,
        scope_token: scopeToken,
      },
    });
    const jobs = JSON.parse(jobResult.content[0].text);
    deployJob = jobs.find(({ name }) => name === deployJobName);
    if (deployJob) break;
  }
  assert.ok(
    deployJob,
    `No ${deployJobName} job found in recent release pipelines`,
  );

  console.log(
    `ok: ${tools.length} tools, projects/pipelines/jobs read verified`,
  );
} finally {
  await client.close();
  httpServer.close();
}
