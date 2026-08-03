# Project Memory

## Purpose

GitLab Deployment MCP is a Streamable HTTP service for Codex, Cursor, Claude Code, and Kimi Code to inspect project pipelines and run an explicitly approved manual deployment Job.

## Authentication

- OAuth is the default mode. `src/server.mjs` refuses OAuth startup unless `GitLabMcpPublicUrl`, `GitLabOAuthClientId`, and `GitLabOAuthClientSecret` are all configured.
- `GitLabMcpAuthMode=personal-token` is the mutually exclusive intranet HTTP mode. It has no OAuth broker or persisted credentials; every client supplies `GITLAB_MCP_ACCESS_TOKEN` in its request header and the server forwards it to GitLab.
- `GitLabBaseUrl` selects the GitLab OAuth endpoints; `GitLabApiUrl` selects the REST API and must include `/api/v4`. Personal-token deployments use `GitLabApiUrl`, not `GitLabBaseUrl`.
- `join-personal-token-macos.sh` is self-contained for intranet `curl | bash`: it stores the token in the macOS login Keychain and configures Codex, Cursor, Kimi Code, and installed Claude Code to reference `GITLAB_MCP_ACCESS_TOKEN`.
- Personal-token onboarding scripts keep the replaceable default URL separate from the example-URL guard, so the documented `sed` rendering changes exactly one occurrence.
- Windows personal-token onboarding treats missing, empty, or whitespace-only Cursor/Kimi MCP files as new JSON objects, while still rejecting malformed or non-object JSON.
- Windows Kimi onboarding writes `~/.kimi-code/mcp.json` and, when Kimi Desktop is installed, `%APPDATA%\kimi-desktop\daimon-share\daimon\runtime\kimi-code\home\mcp.json` for its bundled Kimi Code CLI.
- Claude Code personal-token onboarding uses `claude mcp add --transport http ... --header` with a literal environment-variable reference; `add-json` rejects this HTTP configuration. Native command failures must stop the script.
- `src/oauth.mjs` is the authorization broker: DCR and authorization-code PKCE downstream; one pre-registered GitLab OAuth App upstream with callback `<publicUrl>/oauth/callback`.
- Unauthenticated `/mcp/gitlab-deployment` responses advertise protected-resource metadata through `WWW-Authenticate`; clients use their native OAuth login flow for GitLab authorization.
- In OAuth mode, access and refresh tokens are handled by the client and relayed to GitLab per request. The broker keeps only expiry-bound access-token hashes in memory, so a restart triggers refresh or reauthorization. OAuth credentials never belong in scripts, user environment variables, Codex configuration, or repository files.
- `GitLabOAuthStorePath` persists DCR registrations only, not user credentials.

## Safety Contract

- Every conversation must call `configure_project_scope` with exact project paths and `CONFIRM PROJECT SCOPE` before project-specific reads or writes.
- Deployment requires the selected pipeline, matching SHA, exact manual Job name, and `DEPLOY APPROVED`.
- Keep `default_tools_approval_mode = "writes"`; never hardcode a GitLab Job ID.

## Setup and Verification

- Runtime: Node.js 20 and Yarn 1.x. Use Yarn only.
- HTTP listener defaults to `127.0.0.1:8932`; expose `/mcp/gitlab-deployment`, `/oauth/`, and `/.well-known/` through the HTTPS public URL used by the OAuth App callback. Reserve `/mcp/<service>` for future MCP services.
- With systemd `ProtectSystem=strict`, the directory containing `GitLabOAuthStorePath` must be listed in `ReadWritePaths`; the store contains DCR registrations only.
- `install.ps1` is for Windows self-hosting. It validates OAuth server configuration, installs dependencies, runs tests, and writes a URL-only MCP section.
- `join.ps1` and `join.sh` are static Codex onboarding scripts. `join-cursor.ps1`/`join-cursor.sh` and `join-kimi.ps1`/`join-kimi.sh` safely merge the corresponding MCP URL; macOS scripts use built-in `osascript`. Kimi Code reads `~/.kimi-code/mcp.json`, then users run `/mcp-config login gitlab_deployment`; none of the scripts store user credentials.
- `yarn test` runs installer, onboarding, OAuth, and fake-GitLab personal-token forwarding tests. It never contacts GitLab or runs a deployment.

## Maintenance Rules

- Keep the server small and use the GitLab REST API directly.
- Preserve the confirmed project allowlist, scope-token boundary, and exact deployment-job matching.
- Document all behavior under `docs/`, and update tests with any requirement change.
