# GitLab Deployment MCP

一个供 Codex、Cursor、Claude Code 和 Kimi Code 使用的 GitLab 部署 MCP 服务。它通过 Streamable HTTP 提供项目、Pipeline 和 Job 查询；部署仍须经过项目范围确认、SHA 核对和单独写操作批准。

默认认证是 GitLab OAuth：用户在自己的客户端中打开浏览器，登录 GitLab 并授权。也可以选择与 OAuth 互斥的 Personal Access Token 模式。

## 接入已部署服务

运维部署 OAuth 服务后，按所用平台选择一条命令。所有入口都使用用户自己的 GitLab OAuth；不需要个人 Token。

| 平台 | Windows 入口 | macOS 入口 |
| --- | --- | --- |
| Codex | 托管 `join.ps1` | 托管 `join.sh` |
| Cursor | 托管 `join-cursor.ps1` | 托管 `join-cursor.sh` |
| Claude Code | 原生 `claude mcp add` | 原生 `claude mcp add` |
| Kimi Code | 托管 `join-kimi.ps1` | 托管 `join-kimi.sh` |

### Codex

Windows：

```powershell
irm https://<真实服务地址>/join.ps1 | iex
```

macOS：

```bash
curl -fsSL https://<真实服务地址>/join.sh | bash
```

### Cursor

Windows：

```powershell
irm https://<真实服务地址>/join-cursor.ps1 | iex
```

macOS：

```bash
curl -fsSL https://<真实服务地址>/join-cursor.sh | bash
```

### Claude Code

Windows：

```powershell
claude mcp add --transport http --scope user gitlab_deployment https://<真实服务地址>/mcp/gitlab-deployment
```

macOS：

```bash
claude mcp add --transport http --scope user gitlab_deployment https://<真实服务地址>/mcp/gitlab-deployment
```

### Kimi Code

Windows：

```powershell
irm https://<真实服务地址>/join-kimi.ps1 | iex
```

macOS：

```bash
curl -fsSL https://<真实服务地址>/join-kimi.sh | bash
```

Codex 接入后运行 `codex mcp login gitlab_deployment`；Cursor 接入后运行 `cursor-agent mcp login gitlab_deployment`；Claude Code 接入后启动 `claude` 并输入 `/mcp`；Kimi Code 接入后启动 `kimi` 并输入 `/mcp-config login gitlab_deployment`。四者都会打开浏览器完成 GitLab 授权。Codex 脚本写入 MCP URL、工具白名单和写操作审批配置；Cursor 与 Kimi Code 脚本只写入 MCP URL；Claude Code 使用自身 CLI 写入用户级配置。示例域名 `mcp.internal.company.com` 不是可用服务地址。

## 自行部署服务

服务端部署请按认证方式选择一份手册：

- [GitLab OAuth 部署](docs/deployment.md)：配置 OAuth Application、HTTPS、systemd、nginx 和浏览器登录；
- [Personal Access Token 部署](docs/personal-token.md)：服务端不配置 OAuth，每位用户从本机发送自己的 PAT。

## 首次使用

完成接入后，可以在新 Codex 对话中依次提出：

1. `列出 <GitLab 组路径> 组中的项目`
2. `本次对话只允许操作 <完整项目路径>`
3. `查看这个项目最近的 pipelines`
4. `查看 pipeline <ID> 中的 jobs`

部署前，Codex 必须展示项目、Job、分支、Pipeline ID 和 SHA；只有用户再次批准后才会执行手动 Job。

## 开发验证

```bash
yarn install --frozen-lockfile
yarn test
```

测试使用假 GitLab 完整覆盖 OAuth 授权码、PKCE、刷新令牌和 MCP Bearer 转发，不访问真实 GitLab，也不触发部署。

## 目录

```text
install.ps1             Windows 自行部署安装脚本
join.ps1                Windows OAuth 接入脚本
join-cursor.ps1         Cursor Windows OAuth 接入脚本
join-cursor.sh          Cursor macOS OAuth 接入脚本
join-kimi.ps1           Kimi Code Windows OAuth 接入脚本
join-kimi.sh            Kimi Code macOS OAuth 接入脚本
join.sh                 macOS OAuth 接入脚本
src/server.mjs          MCP HTTP 服务
src/oauth.mjs           GitLab OAuth broker
tests/                  安装、接入、HTTP 与 OAuth 测试
docs/                   运维与使用文档
```
