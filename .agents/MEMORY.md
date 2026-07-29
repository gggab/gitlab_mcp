# Project Memory

## Purpose

This project is a local STDIO MCP server that lets Codex inspect and control deployment workflows in the company GitLab.

## Fixed Scope

- GitLab API: `https://gitlab.sz.sensetime.com/api/v4`
- Allowed group: `ksa/standard-smart-office`, including its subgroups
- Allowed deployment job: exact manual job `deploy to 26 env`
- Access token environment variable: `GitLabAccessToken`
- Never commit, print, log, or share the token.

## MCP Tools

- `list_group_projects`: list projects in the allowed group.
- `list_pipelines`: list recent pipelines for an allowed project.
- `list_pipeline_jobs`: inspect jobs in a selected pipeline.
- `play_deploy_to_26_env`: run only the exact manual deployment job.

## Deployment Safety Contract

- Read the project, pipeline, jobs, ref, and commit SHA before deploying.
- Never hardcode a GitLab job ID; job IDs change for every pipeline.
- Deployment requires the selected pipeline ID, the user-approved commit SHA, and the exact confirmation `DEPLOY TO 26 ENV`.
- Reject deployment when the SHA differs, the job is absent, or the job is not in `manual` status.
- Codex must prompt before write tools by using `default_tools_approval_mode = "writes"`.
- No deployment was executed while implementing or testing this MCP.

## Local Setup and Verification

- Runtime: Node.js 20.
- Entry point: `src/server.mjs`.
- Smoke test: `tests/smoke.mjs`.
- Package manager: Yarn; `yarn.lock` is the lockfile.
- Install: `yarn install --frozen-lockfile`
- Start: `yarn start`
- Verify: `yarn test`
- The smoke test starts the MCP client, checks all four tools, and verifies read-only access to projects, pipelines, and jobs. It never calls the deployment tool.
- Run `yarn audit --groups dependencies` after dependency changes.

## Codex Integration

The StandardSmartOffice workspace currently registers this server from:

`C:\Users\liaowentao\Desktop\WorkSpace\StandardSmartOffice\.codex\config.toml`

The registration must:

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
- Preserve the group allowlist and exact deployment-job restriction.
- Add new write operations only for a confirmed need and give each one an explicit approval boundary.
- Revalidate live GitLab permissions, pipeline structure, and job names before relying on old observations.
