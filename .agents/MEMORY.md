# Project Memory

## Purpose

This project is a local Streamable HTTP MCP server that lets Codex inspect and control deployment workflows in the company GitLab.

## Conversation Scope

- GitLab API: `https://gitlab.sz.sensetime.com/api/v4`
- Project access requires a process-local scope token created after user confirmation.
- Each scope contains exact project paths.
- New sessions without a token must configure their own scope; a session can configure again to change selection.
- Access token environment variable: `GitLabAccessToken` (held by each user's Codex process, forwarded per request).
- Every `/mcp` request must carry `Authorization: Bearer <GitLab token>`; unauthenticated requests get HTTP 401.
- The server never stores tokens; each request's token goes straight to the GitLab API so audit records stay attributable to the caller.
- Never commit, print, log, or share the token.

## MCP Tools

- `configure_project_scope`: confirm exact projects for the conversation.
- `list_group_projects`: discover projects in a requested group.
- `list_pipelines`: list recent pipelines for a project in the confirmed scope.
- `list_pipeline_jobs`: inspect jobs for a project in the confirmed scope.
- `play_deploy_job`: run the exact manual deployment job approved with the selected pipeline and SHA.

## Deployment Safety Contract

- Read the project, pipeline, jobs, ref, and commit SHA before deploying.
- Never hardcode a GitLab job ID; job IDs change for every pipeline.
- Deployment requires the selected pipeline ID, the user-approved commit SHA, and the exact confirmation `DEPLOY APPROVED`.
- Reject deployment when the SHA differs, the job is absent, or the job is not in `manual` status.
- Codex must prompt before write tools by using `default_tools_approval_mode = "writes"`.
- No deployment was executed while implementing or testing this MCP.

## Local Setup and Verification

- Runtime: Node.js 20.
- Entry point: `src/server.mjs`, serving MCP Streamable HTTP on `/mcp` (default `http://127.0.0.1:8932/mcp`; override with `GitLabMcpHost` / `GitLabMcpPort`).
- `startHttpServer({ host, port })` is exported for in-process tests; one MCP session per client, each session gets its own server instance.
- Windows installer: run parameterless `install.ps1` to install dependencies, store the user-scoped token, update `~/.codex/config.toml` with the URL-based MCP section, and verify the server.
- The MCP is user-global and available to all new Codex conversations; project directories are not part of installation.
- The server must be running (`yarn start`) before Codex connects; Codex does not start it in HTTP mode.
- macOS setup is manual: install with Yarn, expose `GitLabAccessToken` to the Codex process, and add the URL-based MCP section to `~/.codex/config.toml`.
- Remove legacy project-local MCP sections after global installation so they cannot override the user configuration.
- Configuration test: `tests/config.test.mjs` (starts the HTTP server in-process on an ephemeral port).
- Optional live smoke test: `tests/smoke.mjs`.
- Package manager: Yarn; `yarn.lock` is the lockfile.
- Install: `yarn install --frozen-lockfile`
- Start: `yarn start`
- Verify: `yarn test`
- Live verify: `yarn test:live`
- The default tests do not access GitLab. The live smoke test checks all five tools and verifies read-only access to projects, pipelines, and jobs. It never calls the deployment tool.
- Run `yarn audit --groups dependencies` after dependency changes.

## Codex Integration

The user-level registration must:

- point `url` at the running server, default `http://127.0.0.1:8932/mcp`;
- forward the per-user token with `bearer_token_env_var = "GitLabAccessToken"`;
- keep the token out of Codex configuration;
- set `default_tools_approval_mode = "writes"`.

Restart Codex after changing MCP configuration or moving the server.

## Distribution

- Publish the source to a private company GitLab repository.
- Do not publish `node_modules` or any access token.
- Each colleague must use their own GitLab token so permissions and audit records remain attributable to that user.
- Teammates run `yarn install --frozen-lockfile`, `yarn test`, point the Codex MCP `url` at their running server, start the server, and restart Codex.
- A centrally hosted instance needs company SSO in front of `/mcp`; per-user tokens remain mandatory so audit records stay attributable.

## Maintenance Rules

- Keep the server small and use the GitLab REST API directly.
- Preserve the confirmed project allowlist, scope-token requirement, and exact deployment-job matching.
- Add new write operations only for a confirmed need and give each one an explicit approval boundary.
- Revalidate live GitLab permissions, pipeline structure, and job names before relying on old observations.
