# 本机运行 OAuth MCP 服务

本文面向开发者或运维人员在自己的机器上运行服务。最终用户应使用已部署服务的 `join.ps1` 或 `join.sh`，不需要克隆仓库、Node 或 Yarn。

## 前提

- Node.js 20+ 和 Yarn 1.x；
- 一个可从浏览器访问的 HTTPS 地址；
- GitLab OAuth App，回调地址精确设置为 `<公开地址>/oauth/callback`，并授权 `api` scope；
- 服务进程可读取 `GitLabMcpPublicUrl`、`GitLabOAuthClientId`、`GitLabOAuthClientSecret`；可选 `GitLabOAuthStorePath` 用于保存 DCR 客户端记录。

`GitLabMcpPublicUrl` 必须是 HTTPS 基地址，例如 `https://mcp.example.com`。本机监听的 `127.0.0.1:8932` 必须由反向代理映射到该公开地址；不能只靠本地 URL 完成浏览器回调。

## Windows

先通过本机安全的环境变量或服务配置方式提供上述 OAuth broker 变量。App Secret 只属于运行服务的机器，不应写入仓库、Codex 配置或接入脚本。

```powershell
cd "C:\Tools\GitLabMCP"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
yarn start
```

安装脚本会检查 OAuth broker 配置、安装依赖、运行测试，并把公开的 `/mcp/gitlab-deployment` 地址写入当前用户的 Codex 配置。它不会提示或保存任何用户凭据。

## macOS

```bash
cd "/Users/me/Tools/GitLabMCP"
yarn install --frozen-lockfile
yarn test
yarn start
```

在启动前，使用服务管理器为 `yarn start` 提供同一组 OAuth broker 环境变量；Codex 配置中的 URL 必须是公开 HTTPS 地址而非本机监听地址。

## 连接 Codex

服务启动后，完全退出并重新打开 Codex，然后执行 `codex mcp login gitlab_deployment` 完成 GitLab 浏览器授权。服务默认监听 `127.0.0.1:8932`，可通过 `GitLabMcpHost` 和 `GitLabMcpPort` 调整；反向代理和 `GitLabMcpPublicUrl` 必须同步。
