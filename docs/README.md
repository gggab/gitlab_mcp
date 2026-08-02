# 项目文档

面向使用者的概览见 [根目录 README](../README.md)。

## 结构

- `install.ps1`：Windows 自行部署安装与 OAuth MCP 配置。
- `join.ps1`、`join.sh`：Codex 的 Windows/macOS 一行 OAuth 接入脚本；`join-cursor.ps1`、`join-cursor.sh`：Cursor 的 Windows/macOS 一行接入脚本；Claude Code 使用原生 `claude mcp add --transport http` 命令；均不保存用户凭据。
- `src/server.mjs`：Streamable HTTP MCP 服务。
- `src/oauth.mjs`：GitLab OAuth broker，提供 DCR 和 PKCE。
- `tests/config.test.mjs`：OAuth 保护的 MCP HTTP 配置测试。
- `tests/oauth.test.mjs`：假 GitLab 上的 OAuth 端到端测试。
- `tests/install.test.ps1`、`tests/join.test.ps1`、`tests/join-cursor.test.ps1`、`tests/join.test.sh`、`tests/join-cursor.test.sh`：安装与接入配置测试。

## 指南

- [内网部署](deployment.md)：systemd、nginx、GitLab OAuth App，以及 Codex、Cursor、Claude Code 的团队接入。
- [本机运行](self-hosting.md)：在自己的机器上运行 OAuth MCP 服务。

## 认证与部署契约

- OAuth broker 是必需项；缺少 `GitLabMcpPublicUrl`、`GitLabOAuthClientId` 或 `GitLabOAuthClientSecret` 时服务拒绝启动。
- 未认证的 `/mcp/gitlab-deployment` 请求返回 401，并通过 `WWW-Authenticate` 公开 OAuth 资源元数据；Codex、Cursor、Claude Code 均可发起浏览器授权。保留 `/mcp/<service>` 给未来的 MCP 服务。
- OAuth access token 仅由客户端在请求中携带；服务只保留带过期时间的内存哈希，不把用户凭据写入配置或磁盘。服务重启后由客户端刷新或重新授权。
- `configure_project_scope` 需要完整项目路径和 `CONFIRM PROJECT SCOPE`。
- `play_deploy_job` 需要精确 Job 名称、匹配 SHA 和 `DEPLOY APPROVED`。

## 测试

```bash
yarn test
```

默认测试不访问真实 GitLab。浏览器授权的真实联调在 OAuth 服务部署后通过 Codex 完成。
