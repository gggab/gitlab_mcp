# Project Memory

## Purpose

This project is a local STDIO MCP server that lets Codex inspect and control deployment workflows in the company GitLab.

## Conversation Scope

- GitLab API: `https://gitlab.sz.sensetime.com/api/v4`
- Project access requires a process-local scope token created after user confirmation.
- Each scope contains exact project paths.
- New conversations without a token must configure their own scope; a conversation can configure again to change selection.
- Access token environment variable: `GitLabAccessToken`
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
- Entry point: `src/server.mjs`.
- Windows installer: run `install.ps1 -Workspace <path>` to install dependencies, store the user-scoped token, update the workspace MCP config, and verify the server.
- Workspace means the project directory where Codex should load this MCP; it is not the GitLabMCP source directory or a GitLab group.
- macOS setup is manual: install with Yarn, expose `GitLabAccessToken` to the Codex process, and add the MCP section to `<workspace>/.codex/config.toml`.
- Configuration test: `tests/config.test.mjs`.
- Optional live smoke test: `tests/smoke.mjs`.
- Package manager: Yarn; `yarn.lock` is the lockfile.
- Install: `yarn install --frozen-lockfile`
- Start: `yarn start`
- Verify: `yarn test`
- Live verify: `yarn test:live`
- The default tests do not access GitLab. The live smoke test checks all five tools and verifies read-only access to projects, pipelines, and jobs. It never calls the deployment tool.
- Run `yarn audit --groups dependencies` after dependency changes.

## Codex Integration

Each target workspace registration must:

- point `args` and `cwd` to this project directory;
- forward `GitLabAccessToken` with `env_vars`;
- set `default_tools_approval_mode = "writes"`.

Restart Codex after changing MCP configuration or moving the server.

## Distribution

- Publish the source to a private company GitLab repository.
- Do not publish `node_modules` or any access token.
- Each colleague must use their own GitLab token so permissions and audit records remain attributable to that user.
- Teammates run `yarn install --frozen-lockfile`, `yarn test`, configure the absolute server path in Codex, and restart Codex.
- Consider a centrally hosted HTTP MCP with company SSO only if local installation becomes a measurable maintenance burden.

## Maintenance Rules

- Keep the server small and use the GitLab REST API directly.
- Preserve the confirmed project allowlist, scope-token requirement, and exact deployment-job matching.
- Add new write operations only for a confirmed need and give each one an explicit approval boundary.
- Revalidate live GitLab permissions, pipeline structure, and job names before relying on old observations.
