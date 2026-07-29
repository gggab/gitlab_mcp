import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const API_URL = "https://gitlab.sz.sensetime.com/api/v4";
const GROUP_PATH = "ksa/standard-smart-office";
const DEPLOY_JOB_NAME = "deploy to 26 env";
const TOKEN_ENV = "GitLabAccessToken";
const PROJECT_PATH_PATTERN =
  /^ksa\/standard-smart-office(?:\/[a-zA-Z0-9_.-]+)+$/;

const readOnly = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
};

const writesDeployment = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: true,
};

function token() {
  const value = process.env[TOKEN_ENV];
  if (!value) {
    throw new Error(`${TOKEN_ENV} is not available to the MCP process`);
  }
  return value;
}

function projectPath(value) {
  if (!PROJECT_PATH_PATTERN.test(value)) {
    throw new Error(`Project must be inside ${GROUP_PATH}`);
  }
  return value;
}

function projectApiPath(value) {
  return encodeURIComponent(projectPath(value));
}

function safeErrorBody(body) {
  return body.replaceAll(token(), "[REDACTED]").slice(0, 500);
}

async function request(path, init = {}) {
  const response = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      "PRIVATE-TOKEN": token(),
      ...init.headers,
    },
    signal: AbortSignal.timeout(30_000),
  });
  const body = await response.text();

  if (!response.ok) {
    throw new Error(
      `GitLab API ${response.status} ${response.statusText}: ${safeErrorBody(body)}`,
    );
  }

  return {
    data: body ? JSON.parse(body) : null,
    headers: response.headers,
  };
}

async function allPages(path) {
  const results = [];
  let page = "1";

  while (page) {
    const separator = path.includes("?") ? "&" : "?";
    const response = await request(`${path}${separator}page=${page}`);
    results.push(...response.data);
    page = response.headers.get("x-next-page");
  }

  return results;
}

function compactPipeline(pipeline) {
  return {
    id: pipeline.id,
    status: pipeline.status,
    ref: pipeline.ref,
    sha: pipeline.sha,
    source: pipeline.source,
    created_at: pipeline.created_at,
    updated_at: pipeline.updated_at,
    web_url: pipeline.web_url,
  };
}

function compactJob(job) {
  return {
    id: job.id,
    name: job.name,
    stage: job.stage,
    status: job.status,
    ref: job.ref,
    pipeline_id: job.pipeline?.id,
    sha: job.commit?.id,
    started_at: job.started_at,
    finished_at: job.finished_at,
    duration: job.duration,
    web_url: job.web_url,
  };
}

function output(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

export function createServer() {
  const server = new McpServer(
    { name: "standard-smart-office-gitlab", version: "1.0.0" },
    {
      instructions:
        `Only access projects under ${GROUP_PATH}. Read before writing. ` +
        `The only deployment write tool plays the exact manual job "${DEPLOY_JOB_NAME}" ` +
        "and requires the user-approved pipeline SHA.",
    },
  );

  server.registerTool(
    "list_group_projects",
    {
      title: "List Standard Smart Office projects",
      description: `List projects under ${GROUP_PATH}, including subgroups.`,
      inputSchema: {
        search: z
          .string()
          .trim()
          .max(100)
          .optional()
          .describe("Optional project-name search"),
      },
      annotations: readOnly,
    },
    async ({ search }) => {
      const query = new URLSearchParams({
        include_subgroups: "true",
        with_shared: "false",
        simple: "true",
        per_page: "100",
      });
      if (search) query.set("search", search);

      const projects = await allPages(
        `/groups/${encodeURIComponent(GROUP_PATH)}/projects?${query}`,
      );
      return output(
        projects.map((project) => ({
          id: project.id,
          name: project.name,
          path_with_namespace: project.path_with_namespace,
          default_branch: project.default_branch,
          archived: project.archived,
          web_url: project.web_url,
        })),
      );
    },
  );

  server.registerTool(
    "list_pipelines",
    {
      title: "List project pipelines",
      description: "List recent pipelines for one project in the allowed group.",
      inputSchema: {
        project_path: z
          .string()
          .describe("Full GitLab path, including all subgroup segments"),
        ref: z.string().trim().max(255).optional(),
        status: z
          .enum([
            "created",
            "waiting_for_resource",
            "preparing",
            "pending",
            "running",
            "success",
            "failed",
            "canceled",
            "skipped",
            "manual",
            "scheduled",
          ])
          .optional(),
        limit: z.number().int().min(1).max(50).default(20),
      },
      annotations: readOnly,
    },
    async ({ project_path, ref, status, limit }) => {
      const query = new URLSearchParams({
        per_page: String(limit),
        order_by: "id",
        sort: "desc",
      });
      if (ref) query.set("ref", ref);
      if (status) query.set("status", status);

      const response = await request(
        `/projects/${projectApiPath(project_path)}/pipelines?${query}`,
      );
      return output(response.data.map(compactPipeline));
    },
  );

  server.registerTool(
    "list_pipeline_jobs",
    {
      title: "List pipeline jobs",
      description:
        `List jobs in a pipeline and identify the manual "${DEPLOY_JOB_NAME}" job.`,
      inputSchema: {
        project_path: z
          .string()
          .describe("Full GitLab path, including all subgroup segments"),
        pipeline_id: z.number().int().positive(),
      },
      annotations: readOnly,
    },
    async ({ project_path, pipeline_id }) => {
      const jobs = await allPages(
        `/projects/${projectApiPath(project_path)}/pipelines/${pipeline_id}/jobs?per_page=100`,
      );
      return output(jobs.map(compactJob));
    },
  );

  server.registerTool(
    "play_deploy_to_26_env",
    {
      title: "Deploy a pipeline to environment 26",
      description:
        `Play only the exact manual GitLab job "${DEPLOY_JOB_NAME}". ` +
        "Call only after showing the project, ref, pipeline ID and SHA to the user and receiving approval.",
      inputSchema: {
        project_path: z
          .string()
          .describe("Full GitLab path, including all subgroup segments"),
        pipeline_id: z.number().int().positive(),
        expected_sha: z
          .string()
          .regex(/^[0-9a-f]{8,40}$/)
          .describe("User-approved full or abbreviated pipeline commit SHA"),
        confirmation: z
          .literal("DEPLOY TO 26 ENV")
          .describe('Exact confirmation text: "DEPLOY TO 26 ENV"'),
      },
      annotations: writesDeployment,
    },
    async ({ project_path, pipeline_id, expected_sha }) => {
      const project = projectApiPath(project_path);
      const pipeline = (
        await request(`/projects/${project}/pipelines/${pipeline_id}`)
      ).data;

      if (!pipeline.sha.startsWith(expected_sha)) {
        throw new Error(
          `Pipeline SHA ${pipeline.sha} does not match approved SHA ${expected_sha}`,
        );
      }

      const jobs = await allPages(
        `/projects/${project}/pipelines/${pipeline_id}/jobs?per_page=100`,
      );
      const job = jobs.find(
        (candidate) =>
          candidate.name === DEPLOY_JOB_NAME && candidate.status === "manual",
      );

      if (!job) {
        const matchingStatuses = jobs
          .filter((candidate) => candidate.name === DEPLOY_JOB_NAME)
          .map((candidate) => candidate.status);
        throw new Error(
          matchingStatuses.length
            ? `"${DEPLOY_JOB_NAME}" is not manual; status: ${matchingStatuses.join(", ")}`
            : `"${DEPLOY_JOB_NAME}" is not present in pipeline ${pipeline_id}`,
        );
      }

      const startedJob = (
        await request(`/projects/${project}/jobs/${job.id}/play`, {
          method: "POST",
        })
      ).data;

      return output({
        action: "deployment_started",
        project_path,
        pipeline: compactPipeline(pipeline),
        job: compactJob(startedJob),
      });
    },
  );

  return server;
}

export async function main() {
  const server = createServer();
  await server.connect(new StdioServerTransport());
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
