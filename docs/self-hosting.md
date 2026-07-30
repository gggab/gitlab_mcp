# 本机运行 MCP 服务（自行部署）

本文面向**在自己电脑上运行 MCP 服务**的场景（开发者或运维本机部署）。同事接入团队已部署的服务不需要克隆本仓库，也不需要 Node/Yarn，直接看 [deployment.md](deployment.md) 的“同事接入”一节。

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

服务默认监听 `http://127.0.0.1:8932/mcp`，可用环境变量 `GitLabMcpHost` 和 `GitLabMcpPort` 修改。修改端口后要同步更新 `~/.codex/config.toml` 中的 `url`。服务本身不再读取 Token：Codex 通过 `bearer_token_env_var = "GitLabAccessToken"` 把你本机环境变量中的 Token 作为 `Authorization: Bearer` 头发给服务。

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

### 2. 把 Token 提供给 Codex

macOS 默认的 zsh 可以隐藏输入 Token，并把它提供给当前登录会话中之后启动的应用：

```zsh
read -s "GITLAB_TOKEN?GitLab Access Token: "
launchctl setenv GitLabAccessToken "$GITLAB_TOKEN"
unset GITLAB_TOKEN
```

Token 不会写入 Codex 配置：Codex 通过 `bearer_token_env_var` 读取该环境变量，并在每个请求中以 `Authorization: Bearer` 头转发给 MCP 服务。注销或重启 macOS 后，需要重新执行这一步。

### 3. 创建全局 Codex 配置

创建或编辑当前用户的 `~/.codex/config.toml`。如果文件已经存在，只添加下面这一段，不要覆盖原有配置：

```toml
[mcp_servers.gitlab_deployment]
url = "http://127.0.0.1:8932/mcp"
bearer_token_env_var = "GitLabAccessToken"
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
