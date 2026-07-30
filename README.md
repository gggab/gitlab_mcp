# GitLab Deployment MCP

这是一个供 Codex 使用的本地 GitLab MCP 服务，通过 Streamable HTTP 提供（默认 `http://127.0.0.1:8932/mcp`）。安装一次后，当前用户的所有新 Codex 会话都可以使用它，不绑定任何项目目录。

它可以查询 GitLab 项目、pipeline 和 job，并在用户单独确认后触发手动部署任务。

## 接入团队已部署的服务（同事）

如果运维已把 MCP 部署到内网服务器，**不需要克隆本仓库，也不需要 Node/Yarn**。创建好个人 GitLab Token（勾选 `api` scope）后，运行一行命令（URL 以运维通知为准）：

```powershell
# Windows（PowerShell）
irm https://mcp.internal.company.com/join.ps1 | iex
```

```bash
# macOS（终端）
curl -fsSL https://mcp.internal.company.com/join.sh | bash
```

脚本会隐藏输入 Token 并安全保存（Windows 存为用户环境变量；macOS 存入登录钥匙串，并在 `~/.zshrc` 追加一行从钥匙串取值的 `export`）、更新用户级 `~/.codex/config.toml`（保留其他配置，可重复运行）。完成后 macOS 同事需新开一个终端，然后完全退出并重新打开 Codex（Codex 需从终端启动）。详见 [docs/deployment.md](docs/deployment.md) 的“同事接入”一节。

## 在自己电脑上运行 MCP 服务

开发者或运维本机部署（Windows 安装程序 / macOS 手动配置 / 启动与重启）见 [docs/self-hosting.md](docs/self-hosting.md)。接入团队服务时不需要。

## 第一次使用

先确认 MCP 服务正在运行（`yarn start`），Codex 通过配置中的 `url` 连接它。

可以按下面的顺序对 Codex 说：

1. `列出 ksa/standard-smart-office 组中的项目`
2. `这个对话只允许操作 ksa/standard-smart-office/frontend/std-smart-office-portal`
3. `查看这个项目 release 分支最近的 pipelines`
4. `查看 pipeline 12345 中的 jobs`

第二步会要求确认仓库范围。确认后，Codex 会自动保存并在后续调用中传递 `scope_token`，用户不需要复制它。新对话会重新确认，也可以在同一对话中重新选择仓库。

部署时，可以说：

`部署 pipeline 12345 中的 deploy to jv 26 env`

Codex 必须先展示项目、部署任务、ref、pipeline ID 和提交 SHA，并再次请求批准。只有名称完全匹配的 `manual` job 才能启动。

## 可用工具

| 工具 | 说明 |
| --- | --- |
| `configure_project_scope` | 确认本次对话允许操作的仓库 |
| `list_group_projects` | 按 GitLab 组查找项目 |
| `list_pipelines` | 查看确认范围内项目的 pipelines |
| `list_pipeline_jobs` | 查看指定 pipeline 中的 jobs |
| `play_deploy_job` | 触发用户批准的手动部署 job |

## 安全边界

- 项目操作前必须确认完整项目路径；
- 后续调用只能访问该次确认范围中的项目；
- 部署任务必须是所选 pipeline 中名称完全匹配的 `manual` job；
- 部署前必须核对项目、任务、ref、pipeline ID 和提交 SHA；
- 部署必须再次获得写操作批准；
- Token 按请求以 `Authorization: Bearer` 头传入，服务不保存 Token，也不应把 Token 写入仓库或 Codex 配置。

## 开发验证

默认测试不访问 GitLab：

```bash
yarn test
```

只读实时验证需要当前进程已经设置 `GitLabAccessToken`：

```bash
export GitLabSmokeProjectPath="company/group/project"
export GitLabSmokeDeployJobName="deploy to test env"
export GitLabSmokeRef="release" # 可选
yarn test:live
```

实时测试不会触发部署。

## 项目结构

```text
install.ps1             Windows 全局安装程序（本机运行服务）
join.ps1                Windows 同事一行接入已部署服务
join.sh                 macOS 同事一行接入已部署服务（Keychain 存储 Token）
src/server.mjs          MCP 服务
tests/config.test.mjs   MCP 配置测试
tests/install.test.ps1  Windows 安装程序测试
tests/join.test.ps1     Windows 一行接入脚本测试
tests/join.test.sh      macOS 一行接入脚本测试（可注入 Keychain stub）
tests/smoke.mjs         GitLab 只读冒烟测试
docs/                   项目维护文档
```
