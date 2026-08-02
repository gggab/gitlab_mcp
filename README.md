# GitLab Deployment MCP

一个供 Codex 使用的 GitLab 部署 MCP 服务。它通过 Streamable HTTP 提供项目、Pipeline 和 Job 查询；部署仍须经过项目范围确认、SHA 核对和单独写操作批准。

认证只有 GitLab OAuth：首次调用时 Codex 打开浏览器，用户登录 GitLab 并授权。用户不需要创建、复制或保存个人访问凭据。

## 接入已部署服务

运维部署 OAuth 服务后，Windows 和 macOS 用户只需运行托管的接入脚本：

```powershell
irm https://<真实服务地址>/join.ps1 | iex
```

```bash
curl -fsSL https://<真实服务地址>/join.sh | bash
```

脚本只写入 MCP URL、工具白名单和写操作审批配置。完全重启 Codex 后，首次使用 GitLab MCP 即会打开 GitLab 授权页。示例域名 `mcp.internal.company.com` 不是可用服务地址。

## 自行部署服务

服务端必须配置一个 GitLab OAuth App、HTTPS 域名，以及：

```text
GitLabMcpPublicUrl
GitLabOAuthClientId
GitLabOAuthClientSecret
GitLabOAuthStorePath
```

详细步骤见 [本机运行](docs/self-hosting.md) 和 [内网部署](docs/deployment.md)。

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
join.sh                 macOS OAuth 接入脚本
src/server.mjs          MCP HTTP 服务
src/oauth.mjs           GitLab OAuth broker
tests/                  安装、接入、HTTP 与 OAuth 测试
docs/                   运维与使用文档
```
