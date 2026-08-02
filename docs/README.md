# Project Documentation

面向使用者的项目说明见 [根目录 README](../README.md)。

## Structure

- `install.ps1`: install and configure the MCP globally for the current Windows user.
- `join.ps1`: one-line onboarding to a centrally hosted MCP for Windows colleagues (no repo clone, no Node/Yarn).
- `join.sh`: one-line onboarding to a centrally hosted MCP for macOS colleagues (Keychain token storage, no repo clone, no Node/Yarn).
- `src/server.mjs`: GitLab MCP server.
- `src/oauth.mjs`: optional OAuth broker (GitLab account sign-in for MCP clients, DCR + PKCE downstream, single pre-registered GitLab OAuth app upstream).
- `tests/config.test.mjs`: runtime configuration test.
- `tests/oauth.test.mjs`: OAuth broker end-to-end test with a fake upstream GitLab; no external access.
- `tests/install.test.ps1`: installer configuration test.
- `tests/join.test.ps1`: one-line onboarding script test (Windows).
- `tests/join.test.sh`: one-line onboarding script test (macOS, injectable Keychain stub).
- `tests/smoke.mjs`: optional read-only GitLab smoke test.

## Guides

- [内网部署手册](deployment.md): intranet hosting with systemd, nginx, and per-user bearer tokens.
- [本机运行 MCP 服务](self-hosting.md): run the MCP server on your own machine (Windows installer, macOS manual setup, start and restart).

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
- Every `/mcp` request must carry `Authorization: Bearer <GitLab token>`; requests without one get HTTP 401. The server never stores tokens and forwards each request's token to the GitLab API as a Bearer header (works for both PATs and OAuth access tokens), so audit records stay attributable to the calling user.
- Optional OAuth broker (`src/oauth.mjs`): enabled only when `GitLabMcpPublicUrl`, `GitLabOAuthClientId`, and `GitLabOAuthClientSecret` are all set (partial config refuses startup). Downstream it is a standard authorization server (DCR limited to loopback redirect URIs, authorization code + S256 PKCE, state required); upstream it is one pre-registered confidential GitLab OAuth app with a fixed callback URI. The token endpoint relays GitLab-issued tokens to clients, so the broker keeps no token state. Client registrations persist to `GitLabOAuthStorePath` when set. With the broker on, 401 responses advertise the protected-resource metadata URL via `WWW-Authenticate`.
- Codex forwards the per-user token with `bearer_token_env_var = "GitLabAccessToken"`.
- Windows uses parameterless `install.ps1` and writes a URL-based MCP section to the current user's `~/.codex/config.toml`.
- macOS installs dependencies with Yarn, exposes `GitLabAccessToken` to the Codex process, and adds the same URL-based MCP section to `~/.codex/config.toml`.
- The server must be running (`yarn start`) before Codex connects; Codex does not start it.
- Previous project-local MCP sections should be removed after global installation so they cannot override the user configuration.
- Colleagues joining a centrally hosted MCP run the hosted `join.ps1` one-liner on Windows (`irm <trusted-url>/join.ps1 | iex`): it stores the per-user token as a user environment variable via hidden input and writes the full URL-based MCP section (URL, `enabled_tools`, `default_tools_approval_mode = "writes"`, `tool_timeout_sec`) into `~/.codex/config.toml`. `codex mcp add --url --bearer-token-env-var` was evaluated and rejected because it writes only `url` and `bearer_token_env_var`, dropping the security-contract fields.
- macOS colleagues run the hosted `join.sh` one-liner (`curl -fsSL <trusted-url>/join.sh | bash`): it stores the per-user token in the login keychain via hidden input (encrypted at rest, reboot-persistent, never plaintext in any file), appends an idempotent keychain-lookup export line to `~/.zshrc` so new shells expose `GitLabAccessToken` to Codex, and writes the same MCP section. The prompt reads from `/dev/tty` so `curl | bash` piping does not break input. `security add-generic-password -w` accepts the value only as an argument, so the token appears briefly in the process argument list during the write; storage itself is encrypted.
- The default MCP URL in `join.ps1` and `join.sh` is the placeholder `https://mcp.internal.company.com/mcp`; each script refuses to run until the deployer replaces it, and the deployer serves the rendered copies through nginx as single static files (`location = /join.ps1`, `location = /join.sh`).
- GUI-launched Codex on macOS (Dock/Spotlight) does not read `~/.zshrc`; colleagues must start Codex from a terminal so it inherits the environment.
