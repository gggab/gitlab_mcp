# GitLab Deployment MCP

这是一个运行在本机的 GitLab MCP 服务。每个对话第一次操作项目前，Codex 会让用户确认本次允许访问的仓库；之后只能在该范围内查询流水线。部署时再单独确认具体任务、pipeline、ref 和提交 SHA。

## 功能

| 工具 | 说明 |
| --- | --- |
| `configure_project_scope` | 确认本次对话允许操作的仓库 |
| `list_group_projects` | 按组查找可选项目 |
| `list_pipelines` | 查看指定项目最近的流水线 |
| `list_pipeline_jobs` | 查看流水线中的任务及部署任务状态 |
| `play_deploy_job` | 触发本次对话确认过的手动部署任务 |

## 安全边界

- 项目操作前必须调用 `configure_project_scope`，并提供用户确认过的完整项目路径。
- 后续项目调用必须携带该次确认返回的 `scope_token`，且只能访问确认列表中的项目。
- 新对话或 MCP 重启后必须重新确认；同一对话也可以再次配置以切换仓库。
- 部署任务名在部署调用时指定，且必须与 pipeline 中的手动任务完全匹配。
- 部署前必须核对项目、流水线、分支和提交 SHA。
- 部署时必须提供用户确认过的 SHA，以及确认文本 `DEPLOY APPROVED`。
- GitLab Token 只通过环境变量传入，不应写入代码、配置文件或提交记录。

## 环境要求

- Node.js 20
- Yarn
- 能够访问公司 GitLab 的账号
- 具有所需权限的 GitLab Access Token

## 安装

在项目根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Workspace "C:\path\to\workspace"
```

安装脚本会：

- 检查 Node.js 和 Yarn；
- 安装依赖；
- 在需要时隐藏输入 GitLab Token，并保存到当前 Windows 用户的环境变量；
- 在目标工作区中添加或更新项目级 Codex MCP 配置；
- 运行测试。

仓库和部署任务都不写入工作区配置：仓库在每个对话中确认，部署任务在实际部署时确认。脚本不会覆盖 `.codex/config.toml` 中的其他配置，也不会把真实 Token 写入仓库。安装成功后需要完全重启 Codex，并打开受信任的目标工作区。

## 运行

```powershell
yarn start
```

这是一个 STDIO MCP 服务，通常由 Codex 启动，不需要单独部署为 Web 服务。接入 Codex 时，需要把服务路径指向本项目，并向 MCP 进程转发 `GitLabAccessToken` 环境变量。部署工具属于写操作，应启用写操作审批。

## 验证

默认测试不访问 GitLab：

```powershell
yarn test
```

需要验证真实 GitLab 只读访问时，先设置测试目标，再运行：

```powershell
$env:GitLabSmokeProjectPath = "company/group/project"
$env:GitLabSmokeDeployJobName = "deploy to test env"
$env:GitLabSmokeRef = "release" # 可选
yarn test:live
```

实时测试需要当前进程可读取 `GitLabAccessToken`，但不会触发部署。

## 项目结构

```text
install.ps1             Codex 一键安装脚本
src/server.mjs          MCP 服务
tests/config.test.mjs   MCP 配置测试
tests/install.test.ps1  安装脚本测试
tests/smoke.mjs         GitLab 只读冒烟测试
docs/                   项目维护文档
```
