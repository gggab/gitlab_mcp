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

## OAuth Broker (optional, src/oauth.mjs)

- Purpose: MCP clients (Kimi CLI, Codex) sign in with their GitLab account via browser OAuth instead of a personal access token; no token lands in any client config file.
- Verified client facts: Kimi CLI has `kimi mcp add --transport http [--auth oauth]` and writes header values literally into `~/.kimi/mcp.json`; fastmcp does NOT expand `${VAR}` env references in headers (tested locally with fastmcp 3.4.5), so static-header registration would force plaintext tokens on disk. OAuth is the only no-plaintext path for Kimi. Figma MCP uses the same standard flow (DCR + PKCE, confirmed by probing its well-known endpoints).
- Downstream the broker is a standard authorization server: DCR at `/oauth/register` (loopback redirect URIs only: localhost/127.0.0.1/[::1], public clients only, `token_endpoint_auth_method = "none"`), authorization code + S256 PKCE at `/oauth/authorize` and `/oauth/token`, `state` required. Refresh grant is relayed upstream.
- Upstream the broker is ONE pre-registered confidential GitLab OAuth app (user-owned app suffices, no admin needed) whose fixed callback URI `<publicUrl>/oauth/callback` absorbs GitLab's exact redirect-URI matching and missing DCR.
- The token endpoint relays GitLab-issued tokens to the client unchanged; the broker keeps no token state, and `/mcp` accepts both PATs and OAuth access tokens.
- Enabled only when `GitLabMcpPublicUrl` + `GitLabOAuthClientId` + `GitLabOAuthClientSecret` are all set; partial configuration refuses startup. `GitLabOAuthStorePath` persists DCR client registrations (no secrets); unset means memory-only. `GitLabBaseUrl` overrides the derived upstream base; `GitLabApiUrl` overrides the GitLab API base (used by tests).
- The server forwards request tokens to the GitLab API with `Authorization: Bearer` (works for PAT and OAuth tokens); it used to send `PRIVATE-TOKEN`.
- With the broker enabled, 401 responses carry `WWW-Authenticate: Bearer resource_metadata="<publicUrl>/.well-known/oauth-protected-resource"` for client discovery; nginx must proxy `/oauth/` and `/.well-known/` (see docs/deployment.md §3 and §5.5).
- GitLab OAuth access tokens expire (default 2h); clients refresh automatically through the broker's relay.
- `tests/oauth.test.mjs` runs the full flow against a fake upstream GitLab (authorize/token/API), zero external access: metadata, DCR validation, PKCE binding, single-use codes, refresh relay, Bearer forwarding, PAT regression, 401 discovery header, persistence across restart, disabled-by-default.

## Distribution

- Publish the source to a private company GitLab repository.
- Do not publish `node_modules` or any access token.
- Each colleague must use their own GitLab token so permissions and audit records remain attributable to that user.
- Teammates run `yarn install --frozen-lockfile`, `yarn test`, point the Codex MCP `url` at their running server, start the server, and restart Codex.
- A centrally hosted instance needs company SSO in front of `/mcp`; per-user tokens remain mandatory so audit records stay attributable.

## Colleague Onboarding (centrally hosted MCP)

- `join.ps1` is the one-line Windows onboarding: `irm <trusted-https-url>/join.ps1 | iex`. No repo clone, no Node/Yarn, no manual `config.toml` edit.
- It hidden-prompts the personal token, persists it as the user environment variable `GitLabAccessToken`, and writes the full MCP section (`url`, `bearer_token_env_var`, `enabled_tools`, `default_tools_approval_mode = "writes"`, `tool_timeout_sec = 60`) into user-level `~/.codex/config.toml`, preserving other settings and staying idempotent.
- `join.sh` is the equivalent one-line macOS onboarding: `curl -fsSL <trusted-https-url>/join.sh | bash`. It stores the token in the login keychain (`security add-generic-password -U -s GitLabAccessToken`, encrypted at rest, reboot-persistent, never plaintext in any file) and appends one idempotent export line marked `# gitlab-mcp-join` to `~/.zshrc` that resolves the token from the keychain when a new shell starts. Codex must be started from a terminal to inherit it; GUI-launched Codex does not read `~/.zshrc`.
- `join.sh` design notes: the hidden prompt reads from `/dev/tty` because `curl | bash` occupies stdin with the script itself; `security add-generic-password -w` accepts the value only as an argument, so the token appears briefly in the process argument list during the write (same class as any CLI credential flag; storage stays encrypted); if `GitLabAccessToken` already exists only in the environment (e.g. an earlier `launchctl setenv`), the script migrates it into the keychain; the script runs its `onboard` entry only when executed, not when sourced by tests.
- Test seams in `join.sh`: `JOIN_MCP_URL`, `JOIN_CONFIG_DIR`, `JOIN_SHELL_PROFILE`, `JOIN_SECURITY` (injectable keychain stub). `tests/join.test.sh` stubs `security` with a file-backed fake and never touches the real keychain, profile, or `~/.codex`.
- `codex mcp add <name> --url ... --bearer-token-env-var ...` was evaluated and rejected: verified locally (CODEX_HOME sandbox) that it writes only `url` and `bearer_token_env_var`, so it cannot keep the security-contract fields. The scripts write the config section directly instead.
- The default URL in `join.ps1` and `join.sh` is the placeholder `https://mcp.internal.company.com/mcp`; each script refuses to run until the deployer replaces it. Never present the placeholder as a real production domain.
- The deployer renders hosted copies with the real URL (sed replace) and serves them through nginx as single static files (`location = /join.ps1`, `location = /join.sh`, `default_type text/plain`); do not add a Node endpoint to serve the scripts.
- Both join scripts are pure ASCII on purpose: they are fetched through `irm | iex` / `curl | bash`, and non-ASCII content can be mis-decoded by Windows PowerShell 5.1.
- `tests/join.test.ps1` covers new/existing config, unrelated-config preservation, legacy and outdated section replacement, idempotency, remote URL, security fields, and token hygiene; it never touches the real user environment or `~/.codex` (config directory and token scope are injectable). `tests/join.test.sh` mirrors that coverage for macOS plus keychain storage idempotency, profile-line idempotency/legacy plaintext removal, environment-token migration, and end-to-end onboarding.

## Maintenance Rules

- Keep the server small and use the GitLab REST API directly.
- Preserve the confirmed project allowlist, scope-token requirement, and exact deployment-job matching.
- Add new write operations only for a confirmed need and give each one an explicit approval boundary.
- Revalidate live GitLab permissions, pipeline structure, and job names before relying on old observations.
