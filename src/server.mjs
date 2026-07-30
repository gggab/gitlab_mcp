import { randomUUID } from "node:crypto";
import { createServer as createHttpServer } from "node:http";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

const API_URL = "https://gitlab.sz.sensetime.com/api/v4";
export const MCP_PATH = "/mcp";
export const DEFAULT_HOST = "127.0.0.1";
export const DEFAULT_PORT = 8932;
const HOST_ENV = "GitLabMcpHost";
const PORT_ENV = "GitLabMcpPort";
const GITLAB_PATH_PATTERN =
  /^[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)*$/;
// ponytail: process-local scopes last until restart; add expiry only if long-lived servers accumulate them.
const scopes = new Map();

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

const changesScope = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
};

function bearerToken(extra) {
  const header = extra?.requestInfo?.headers?.["authorization"];
  const value = Array.isArray(header) ? header[0] : header;
  const match = typeof value === "string" && /^Bearer\s+(\S+)$/i.exec(value);
  if (!match) {
    throw new Error("Request must carry an Authorization: Bearer <GitLab token> header");
  }
  return match[1];
}

function gitlabPath(value, label) {
  if (!GITLAB_PATH_PATTERN.test(value)) {
    throw new Error(`${label} is not a valid GitLab path`);
  }
  return value;
}

function selectedProject(value, scopeToken) {
  gitlabPath(value, "Project");
  const selectedScope = scopes.get(scopeToken);
  if (!selectedScope) {
    throw new Error("Project scope is missing; confirm repositories first");
  }
  if (!selectedScope.projectPaths.has(value)) {
    throw new Error(`Project ${value} is outside the confirmed project scope`);
  }
  return {
    apiPath: encodeURIComponent(value),
  };
}

function safeErrorBody(body, gitlabToken) {
  return body.replaceAll(gitlabToken, "[REDACTED]").slice(0, 500);
}

async function request(path, gitlabToken, init = {}) {
  const response = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      "PRIVATE-TOKEN": gitlabToken,
      ...init.headers,
    },
    signal: AbortSignal.timeout(30_000),
  });
  const body = await response.text();

  if (!response.ok) {
    throw new Error(
      `GitLab API ${response.status} ${response.statusText}: ${safeErrorBody(body, gitlabToken)}`,
    );
  }

  return {
    data: body ? JSON.parse(body) : null,
    headers: response.headers,
  };
}

async function allPages(path, gitlabToken) {
  const results = [];
  let page = "1";

  while (page) {
    const separator = path.includes("?") ? "&" : "?";
    const response = await request(`${path}${separator}page=${page}`, gitlabToken);
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
    { name: "gitlab-deployment", version: "1.0.0" },
    {
      instructions:
        "Use list_group_projects only for discovery. Before listing pipelines or jobs, show the exact repositories to the user, " +
        "then call configure_project_scope after confirmation. Pass its scope token to later calls. " +
        "Before deployment, show the exact job, pipeline, ref and SHA and obtain separate approval.",
    },
  );

  server.registerTool(
    "configure_project_scope",
    {
      title: "Confirm repositories for this conversation",
      description:
        "Create a conversation scope for exact repositories. " +
        "Call only after showing them to the user and receiving confirmation. " +
        "Call again to select different repositories.",
      inputSchema: {
        project_paths: z
          .array(z.string().max(255))
          .min(1)
          .max(50)
          .describe("Exact GitLab project paths approved by the user"),
        confirmation: z
          .literal("CONFIRM PROJECT SCOPE")
          .describe('Exact confirmation text: "CONFIRM PROJECT SCOPE"'),
      },
      annotations: changesScope,
    },
    async ({ project_paths }) => {
      if (new Set(project_paths).size !== project_paths.length) {
        throw new Error("Project scope contains duplicate paths");
      }
      for (const projectPath of project_paths) {
        gitlabPath(projectPath, "Project");
        if (!projectPath.includes("/")) {
          throw new Error(`Project is not a full GitLab path: ${projectPath}`);
        }
      }

      const scopeToken = randomUUID();
      scopes.set(scopeToken, {
        projectPaths: new Set(project_paths),
      });
      return output({
        scope_token: scopeToken,
        project_paths,
      });
    },
  );

  server.registerTool(
    "list_group_projects",
    {
      title: "List GitLab group projects",
      description: "List projects under a GitLab group, including subgroups.",
      inputSchema: {
        group_path: z
          .string()
          .max(255)
          .describe("GitLab group path to inspect"),
        search: z
          .string()
          .trim()
          .max(100)
          .optional()
          .describe("Optional project-name search"),
      },
      annotations: readOnly,
    },
    async ({ group_path, search }, extra) => {
      const gitlabToken = bearerToken(extra);
      const group = gitlabPath(group_path, "Group");
      const query = new URLSearchParams({
        include_subgroups: "true",
        with_shared: "false",
        simple: "true",
        per_page: "100",
      });
      if (search) query.set("search", search);

      const projects = await allPages(
        `/groups/${encodeURIComponent(group)}/projects?${query}`,
        gitlabToken,
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
      description: "List recent pipelines for one project in the confirmed scope.",
      inputSchema: {
        scope_token: z
          .string()
          .uuid()
          .describe("Token returned by configure_project_scope"),
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
    async ({ scope_token, project_path, ref, status, limit }, extra) => {
      const gitlabToken = bearerToken(extra);
      const project = selectedProject(project_path, scope_token).apiPath;
      const query = new URLSearchParams({
        per_page: String(limit),
        order_by: "id",
        sort: "desc",
      });
      if (ref) query.set("ref", ref);
      if (status) query.set("status", status);

      const response = await request(
        `/projects/${project}/pipelines?${query}`,
        gitlabToken,
      );
      return output(response.data.map(compactPipeline));
    },
  );

  server.registerTool(
    "list_pipeline_jobs",
    {
      title: "List pipeline jobs",
      description:
        "List jobs in a pipeline for a project in the confirmed scope.",
      inputSchema: {
        scope_token: z
          .string()
          .uuid()
          .describe("Token returned by configure_project_scope"),
        project_path: z
          .string()
          .describe("Full GitLab path, including all subgroup segments"),
        pipeline_id: z.number().int().positive(),
      },
      annotations: readOnly,
    },
    async ({ scope_token, project_path, pipeline_id }, extra) => {
      const gitlabToken = bearerToken(extra);
      const project = selectedProject(project_path, scope_token).apiPath;
      const jobs = await allPages(
        `/projects/${project}/pipelines/${pipeline_id}/jobs?per_page=100`,
        gitlabToken,
      );
      return output(jobs.map(compactJob));
    },
  );

  server.registerTool(
    "play_deploy_job",
    {
      title: "Play the confirmed deployment job",
      description:
        "Play only the exact manual GitLab job confirmed in the project scope. " +
        "Call only after showing the project, ref, pipeline ID and SHA to the user and receiving approval.",
      inputSchema: {
        scope_token: z
          .string()
          .uuid()
          .describe("Token returned by configure_project_scope"),
        project_path: z
          .string()
          .describe("Full GitLab path, including all subgroup segments"),
        pipeline_id: z.number().int().positive(),
        deploy_job_name: z
          .string()
          .min(1)
          .max(255)
          .regex(/^(?=.*\S)[^\r\n]+$/)
          .describe("Exact manual deployment job approved by the user"),
        expected_sha: z
          .string()
          .regex(/^[0-9a-f]{8,40}$/)
          .describe("User-approved full or abbreviated pipeline commit SHA"),
        confirmation: z
          .literal("DEPLOY APPROVED")
          .describe('Exact confirmation text: "DEPLOY APPROVED"'),
      },
      annotations: writesDeployment,
    },
    async ({
      scope_token,
      project_path,
      pipeline_id,
      deploy_job_name,
      expected_sha,
    }, extra) => {
      const gitlabToken = bearerToken(extra);
      const selected = selectedProject(project_path, scope_token);
      const project = selected.apiPath;
      const pipeline = (
        await request(`/projects/${project}/pipelines/${pipeline_id}`, gitlabToken)
      ).data;

      if (!pipeline.sha.startsWith(expected_sha)) {
        throw new Error(
          `Pipeline SHA ${pipeline.sha} does not match approved SHA ${expected_sha}`,
        );
      }

      const jobs = await allPages(
        `/projects/${project}/pipelines/${pipeline_id}/jobs?per_page=100`,
        gitlabToken,
      );
      const job = jobs.find(
        (candidate) =>
          candidate.name === deploy_job_name && candidate.status === "manual",
      );

      if (!job) {
        const matchingStatuses = jobs
          .filter((candidate) => candidate.name === deploy_job_name)
          .map((candidate) => candidate.status);
        throw new Error(
          matchingStatuses.length
            ? `"${deploy_job_name}" is not manual; status: ${matchingStatuses.join(", ")}`
            : `"${deploy_job_name}" is not present in pipeline ${pipeline_id}`,
        );
      }

      const startedJob = (
        await request(`/projects/${project}/jobs/${job.id}/play`, gitlabToken, {
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

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("error", reject);
    req.on("end", () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : null);
      } catch (error) {
        reject(new Error("Request body is not valid JSON"));
      }
    });
  });
}

function writeJsonRpcError(res, status, message) {
  if (!res.headersSent) {
    res.writeHead(status, { "content-type": "application/json" });
  }
  res.end(
    JSON.stringify({
      jsonrpc: "2.0",
      error: { code: -32000, message },
      id: null,
    }),
  );
}

export function startHttpServer({ host, port } = {}) {
  const listenHost = host ?? process.env[HOST_ENV] ?? DEFAULT_HOST;
  const listenPort = port ?? Number(process.env[PORT_ENV] ?? DEFAULT_PORT);
  const transports = new Map();

  const httpServer = createHttpServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      console.error(error);
      writeJsonRpcError(res, 500, "Internal server error");
    });
  });

  async function handleRequest(req, res) {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname !== MCP_PATH) {
      writeJsonRpcError(res, 404, `Unknown path: ${url.pathname}`);
      return;
    }

    const authorization = req.headers.authorization;
    if (typeof authorization !== "string" || !/^Bearer\s+\S+$/i.test(authorization)) {
      res.writeHead(401, { "www-authenticate": "Bearer" });
      writeJsonRpcError(res, 401, "Authorization: Bearer <GitLab token> is required");
      return;
    }

    const sessionId = req.headers["mcp-session-id"];
    const transport =
      typeof sessionId === "string" ? transports.get(sessionId) : undefined;

    if (transport) {
      await transport.handleRequest(req, res);
      return;
    }

    if (sessionId !== undefined || req.method !== "POST") {
      writeJsonRpcError(res, 400, "Unknown or missing MCP session");
      return;
    }

    const body = await readJsonBody(req);
    if (!isInitializeRequest(body)) {
      writeJsonRpcError(res, 400, "First request must be an MCP initialize request");
      return;
    }

    const newTransport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (id) => {
        transports.set(id, newTransport);
      },
    });
    newTransport.onclose = () => {
      if (newTransport.sessionId) {
        transports.delete(newTransport.sessionId);
      }
    };
    await createServer().connect(newTransport);
    await newTransport.handleRequest(req, res, body);
  }

  return new Promise((resolve, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(listenPort, listenHost, () => {
      httpServer.off("error", reject);
      const address = httpServer.address();
      resolve({ httpServer, host: listenHost, port: address.port });
    });
  });
}

export async function main() {
  const { host, port } = await startHttpServer();
  console.log(`GitLab deployment MCP listening on http://${host}:${port}${MCP_PATH}`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
