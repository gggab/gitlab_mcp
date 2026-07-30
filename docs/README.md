# Project Documentation

面向使用者的项目说明见 [根目录 README](../README.md)。

## Structure

- `install.ps1`: install and configure the MCP globally for the current Windows user.
- `src/server.mjs`: GitLab MCP server.
- `tests/config.test.mjs`: runtime configuration test.
- `tests/install.test.ps1`: installer configuration test.
- `tests/smoke.mjs`: optional read-only GitLab smoke test.

## Deployment Contract

- `configure_project_scope` requires exact project paths and `CONFIRM PROJECT SCOPE`.
- It returns a process-local `scope_token`; every project-specific read or write tool requires that token.
- A scope allows only its exact project list.
- A new conversation without the token must configure a new scope. Calling the tool again allows a different selection.
- `list_group_projects` remains available without a scope for read-only discovery.
- `play_deploy_job` receives the exact manual job name at deployment time.
- Required confirmation: `DEPLOY APPROVED`.

## Tests

- `yarn test`: installer and runtime configuration tests; no GitLab access.
- `yarn test:live`: read-only GitLab smoke test using `GitLabSmokeProjectPath`, `GitLabSmokeDeployJobName`, and optional `GitLabSmokeRef`.

## Platform Setup

- The server speaks MCP Streamable HTTP on `/mcp`; defaults: host `127.0.0.1`, port `8932`, overridable with `GitLabMcpHost` and `GitLabMcpPort`.
- Every `/mcp` request must carry `Authorization: Bearer <GitLab token>`; requests without one get HTTP 401. The server never stores tokens and forwards each request's token to the GitLab API, so audit records stay attributable to the calling user.
- Codex forwards the per-user token with `bearer_token_env_var = "GitLabAccessToken"`.
- Windows uses parameterless `install.ps1` and writes a URL-based MCP section to the current user's `~/.codex/config.toml`.
- macOS installs dependencies with Yarn, exposes `GitLabAccessToken` to the Codex process, and adds the same URL-based MCP section to `~/.codex/config.toml`.
- The server must be running (`yarn start`) before Codex connects; Codex does not start it.
- Previous project-local MCP sections should be removed after global installation so they cannot override the user configuration.
