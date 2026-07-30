# GitLab Deployment MCP

这是一个供 Codex 使用的本地 GitLab MCP 服务，通过 Streamable HTTP 提供（默认 `http://127.0.0.1:8932/mcp`）。安装一次后，当前用户的所有新 Codex 会话都可以使用它，不绑定任何项目目录。

它可以查询 GitLab 项目、pipeline 和 job，并在用户单独确认后触发手动部署任务。

## 准备工作

安装前需要：

- Node.js 20 或更高版本；
- Yarn 1.x；
- 能访问公司 GitLab 的账号；
- 一个具有所需读取和部署权限的 GitLab Access Token；
- 已下载或克隆到本机的 GitLabMCP 项目。

Token 不要写入代码、README 或 `config.toml`。

## Windows 安装

### 1. 打开 GitLabMCP 目录

在 PowerShell 中进入本项目目录：

```powershell
cd "C:\Tools\GitLabMCP"
```

### 2. 运行安装程序

安装命令不需要参数：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装程序会：

1. 检查 Node.js 和 Yarn；
2. 安装依赖并运行测试；
3. 在需要时隐藏输入 GitLab Token，并保存到当前 Windows 用户环境变量；
4. 创建或更新 `C:\Users\<当前用户>\.codex\config.toml`；
5. 保留该配置文件中的其他设置。

### 3. 启动 MCP 服务

HTTP 模式下 Codex 不会自动启动服务，需要先运行：

```powershell
yarn start
```

服务默认监听 `http://127.0.0.1:8932/mcp`，可用环境变量 `GitLabMcpHost` 和 `GitLabMcpPort` 修改。修改端口后要同步更新 `~/.codex/config.toml` 中的 `url`。Token 由服务进程读取，请从能看到 `GitLabAccessToken` 用户环境变量的新终端中启动。

### 4. 重启 Codex

完全退出并重新打开 Codex。已经运行的 Codex 进程看不到新设置的环境变量或 MCP 配置，因此只新建一个任务还不够。

重启后，不论打开哪个项目，新会话都可以使用 GitLab MCP。

## macOS 安装

`install.ps1` 是 Windows 安装程序。macOS 手动完成一次全局配置即可。

以下示例假设 GitLabMCP 位于 `/Users/me/Tools/GitLabMCP`。

### 1. 安装依赖并验证

```bash
cd "/Users/me/Tools/GitLabMCP"
yarn install --frozen-lockfile
yarn test
command -v node
```

记下 `command -v node` 输出的绝对路径，例如 `/opt/homebrew/bin/node`。

### 2. 把 Token 提供给 MCP 服务

macOS 默认的 zsh 可以隐藏输入 Token，并把它提供给当前登录会话中之后启动的应用：

```zsh
read -s "GITLAB_TOKEN?GitLab Access Token: "
launchctl setenv GitLabAccessToken "$GITLAB_TOKEN"
unset GITLAB_TOKEN
```

Token 由 MCP 服务进程读取，不会写入 Codex 配置。注销或重启 macOS 后，需要重新执行这一步。

### 3. 创建全局 Codex 配置

创建或编辑当前用户的 `~/.codex/config.toml`。如果文件已经存在，只添加下面这一段，不要覆盖原有配置：

```toml
[mcp_servers.gitlab_deployment]
url = "http://127.0.0.1:8932/mcp"
enabled_tools = [
  "configure_project_scope",
  "list_group_projects",
  "list_pipelines",
  "list_pipeline_jobs",
  "play_deploy_job",
]
default_tools_approval_mode = "writes"
tool_timeout_sec = 60
enabled = true
```

### 4. 启动 MCP 服务并重启 Codex

先启动服务：

```bash
cd "/Users/me/Tools/GitLabMCP"
yarn start
```

服务默认监听 `http://127.0.0.1:8932/mcp`，可用 `GitLabMcpHost` 和 `GitLabMcpPort` 修改，修改端口后要同步更新配置中的 `url`。然后完全退出并重新打开 Codex，之后所有新会话都可以使用 GitLab MCP。

## 从旧版本迁移

如果以前使用过带 `-Workspace` 参数的安装方式，旧项目的 `.codex/config.toml` 中可能仍有 `[mcp_servers.gitlab_deployment]` 或 `[mcp_servers.standard_smart_office_gitlab]`。

完成全局安装后，可以从旧项目配置中删除这些 MCP 段，避免项目级旧配置覆盖用户级新配置。不要删除该文件中的其他设置。

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
- Token 只通过环境变量传入，不应写入仓库或 Codex 配置。

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
install.ps1             Windows 全局安装程序
src/server.mjs          MCP 服务
tests/config.test.mjs   MCP 配置测试
tests/install.test.ps1  Windows 安装程序测试
tests/smoke.mjs         GitLab 只读冒烟测试
docs/                   项目维护文档
```
