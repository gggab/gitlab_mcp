# Project Documentation

面向使用者的项目说明见 [根目录 README](../README.md)。

## Structure

- `install.ps1`: install and configure the MCP for a Codex workspace.
- `src/server.mjs`: GitLab MCP server.
- `tests/install.test.ps1`: installer configuration test.
- `tests/smoke.mjs`: MCP smoke test.

## Deployment Contract

- Target environment: `jv26`.
- Exact GitLab manual job: `deploy to jv 26 env`.
- Write tool: `play_deploy_to_jv26_env`.
- Required confirmation: `DEPLOY TO JV 26 ENV`.
