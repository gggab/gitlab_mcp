# Standard Smart Office GitLab MCP

这是一个运行在本机的 GitLab MCP 服务，让 Codex 能够查询 Standard Smart Office 项目的流水线，并在用户明确确认后触发 26 环境部署。

## 功能

| 工具 | 说明 |
| --- | --- |
| `list_group_projects` | 列出 `ksa/standard-smart-office` 组及子组中的项目 |
| `list_pipelines` | 查看指定项目最近的流水线 |
| `list_pipeline_jobs` | 查看流水线中的任务及部署任务状态 |
| `play_deploy_to_26_env` | 触发手动任务 `deploy to 26 env` |

## 安全边界

- 只能访问 `ksa/standard-smart-office` 组及其子组。
- 只能触发名称完全匹配 `deploy to 26 env` 的手动任务。
- 部署前必须核对项目、流水线、分支和提交 SHA。
- 部署时必须提供用户确认过的 SHA，以及确认文本 `DEPLOY TO 26 ENV`。
- GitLab Token 只通过环境变量传入，不应写入代码、配置文件或提交记录。

## 环境要求

- Node.js 20
- Yarn
- 能够访问公司 GitLab 的账号
- 具有所需权限的 GitLab Access Token

## 安装

在项目根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Workspace "C:\path\to\StandardSmartOffice"
```

安装脚本会：

- 检查 Node.js 和 Yarn；
- 安装依赖；
- 在需要时隐藏输入 GitLab Token，并保存到当前 Windows 用户的环境变量；
- 在目标工作区中添加或更新项目级 Codex MCP 配置；
- 运行测试。

脚本不会覆盖 `.codex/config.toml` 中的其他配置，也不会把真实 Token 写入仓库。安装成功后需要完全重启 Codex，并打开受信任的目标工作区。

## 运行

```powershell
yarn start
```

这是一个 STDIO MCP 服务，通常由 Codex 启动，不需要单独部署为 Web 服务。接入 Codex 时，需要把服务路径指向本项目，并向 MCP 进程转发 `GitLabAccessToken` 环境变量。部署工具属于写操作，应启用写操作审批。

## 验证

```powershell
yarn test
```

冒烟测试会连接公司 GitLab，验证四个工具以及项目、流水线和任务的只读查询。测试不会触发部署。

## 项目结构

```text
install.ps1             Codex 一键安装脚本
src/server.mjs          MCP 服务
tests/install.test.ps1  安装脚本测试
tests/smoke.mjs         MCP 冒烟测试
docs/                   项目维护文档
```
