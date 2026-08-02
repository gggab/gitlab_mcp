# Project Memory

## Purpose

GitLab Deployment MCP is a Streamable HTTP service for Codex to inspect project pipelines and run an explicitly approved manual deployment Job.

## Authentication

- OAuth is mandatory. `src/server.mjs` refuses startup unless `GitLabMcpPublicUrl`, `GitLabOAuthClientId`, and `GitLabOAuthClientSecret` are all configured.
- `src/oauth.mjs` is the authorization broker: DCR and authorization-code PKCE downstream; one pre-registered GitLab OAuth App upstream with callback `<publicUrl>/oauth/callback`.
- Unauthenticated `/mcp/gitlab-deployment` responses advertise protected-resource metadata through `WWW-Authenticate`; Codex opens the browser for GitLab authorization.
- OAuth access and refresh tokens are handled by the client and relayed to GitLab per request. The broker keeps only expiry-bound access-token hashes in memory, so a restart triggers refresh or reauthorization. User credentials never belong in scripts, user environment variables, Codex configuration, or repository files.
- `GitLabOAuthStorePath` persists DCR registrations only, not user credentials.

## Safety Contract

- Every conversation must call `configure_project_scope` with exact project paths and `CONFIRM PROJECT SCOPE` before project-specific reads or writes.
- Deployment requires the selected pipeline, matching SHA, exact manual Job name, and `DEPLOY APPROVED`.
- Keep `default_tools_approval_mode = "writes"`; never hardcode a GitLab Job ID.

## Setup and Verification

- Runtime: Node.js 20 and Yarn 1.x. Use Yarn only.
- HTTP listener defaults to `127.0.0.1:8932`; expose `/mcp/gitlab-deployment`, `/oauth/`, and `/.well-known/` through the HTTPS public URL used by the OAuth App callback. Reserve `/mcp/<service>` for future MCP services.
- `install.ps1` is for Windows self-hosting. It validates OAuth server configuration, installs dependencies, runs tests, and writes a URL-only MCP section.
- `join.ps1` and `join.sh` are static hosted onboarding scripts. They write the managed MCP section only; after a full Codex restart, browser authorization happens on first use.
- `yarn test` runs installer, onboarding, configuration, and fake-GitLab OAuth tests. It never contacts GitLab or runs a deployment.

## Maintenance Rules

- Keep the server small and use the GitLab REST API directly.
- Preserve the confirmed project allowlist, scope-token boundary, and exact deployment-job matching.
- Document all behavior under `docs/`, and update tests with any requirement change.
