import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: ["../src/server.mjs"],
  cwd: import.meta.dirname,
  env: {
    ...process.env,
    GitLabAccessToken: process.env.GitLabAccessToken,
  },
});
const client = new Client({ name: "gitlab-mcp-smoke", version: "1.0.0" });

try {
  await client.connect(transport);

  const { tools } = await client.listTools();
  assert.deepEqual(
    tools.map(({ name }) => name),
    [
      "list_group_projects",
      "list_pipelines",
      "list_pipeline_jobs",
      "play_deploy_to_jv26_env",
    ],
  );
  assert.equal(
    tools.find(({ name }) => name === "play_deploy_to_jv26_env").annotations
      .readOnlyHint,
    false,
  );

  const result = await client.callTool({
    name: "list_group_projects",
    arguments: { search: "std-smart-office-portal" },
  });
  const projects = JSON.parse(result.content[0].text);
  const portalPath =
    "ksa/standard-smart-office/frontend/std-smart-office-portal";
  assert.ok(
    projects.some(
      ({ path_with_namespace }) => path_with_namespace === portalPath,
    ),
  );

  const pipelineResult = await client.callTool({
    name: "list_pipelines",
    arguments: { project_path: portalPath, ref: "release", limit: 10 },
  });
  const pipelines = JSON.parse(pipelineResult.content[0].text);
  assert.ok(pipelines.length > 0);

  let deployJob;
  for (const pipeline of pipelines) {
    const jobResult = await client.callTool({
      name: "list_pipeline_jobs",
      arguments: { project_path: portalPath, pipeline_id: pipeline.id },
    });
    const jobs = JSON.parse(jobResult.content[0].text);
    deployJob = jobs.find(({ name }) => name === "deploy to jv 26 env");
    if (deployJob) break;
  }
  assert.ok(
    deployJob,
    "No deploy to jv 26 env job found in recent release pipelines",
  );

  console.log(
    `ok: ${tools.length} tools, projects/pipelines/jobs read verified`,
  );
} finally {
  await client.close();
}
