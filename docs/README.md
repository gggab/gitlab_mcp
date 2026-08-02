# 项目文档

面向使用者的功能概览见[根目录 README](../README.md)。服务端部署先选择一种认证模式：

| 模式 | 适用场景 | 服务端保存用户凭据 | 部署手册 |
| --- | --- | --- | --- |
| GitLab OAuth（默认） | 有可信 HTTPS 地址，多人通过浏览器登录 | 否；仅持有内存 Token 哈希 | [OAuth 部署](deployment.md) |
| Personal Access Token | 明确不使用 OAuth，用户各自管理 PAT | 否；每次请求直接转发用户 PAT | [Token 部署](personal-token.md) |

两种模式互斥。OAuth 需要 `GitLabMcpPublicUrl`、OAuth Application ID 和 Secret；Personal Token 模式必须设置 `GitLabMcpAuthMode=personal-token`，且不能保留 OAuth 配置。

## 源码对应关系

- `src/server.mjs`：Streamable HTTP MCP、认证模式选择、GitLab REST API 和部署安全边界。
- `src/oauth.mjs`：OAuth broker，提供 DCR、授权码、PKCE 和刷新令牌转发。
- `install.ps1`：Windows 本机 OAuth 安装；不用于 Personal Token 模式。
- `join*.ps1`、`join*.sh`：OAuth 客户端接入脚本。
- `join-personal-token.ps1`、`join-personal-token-macos.sh`：Personal Token 客户端接入脚本。
- `tests/`：安装、接入、OAuth 与 Personal Token 测试；默认不访问真实 GitLab。

## 两种模式共同的操作边界

- 每次对话先用完整项目路径和 `CONFIRM PROJECT SCOPE` 调用 `configure_project_scope`。
- 部署前必须展示项目、Job、分支、Pipeline ID 和 SHA。
- `play_deploy_job` 只接受精确的手动 Job 名称、匹配的 SHA 和 `DEPLOY APPROVED`。
- Pipeline Job ID 必须实时查询，不能写死。

## 验证

```bash
yarn test
```

真实环境上线验收只做认证接入和只读查询；不要用验收流程触发真实部署。
