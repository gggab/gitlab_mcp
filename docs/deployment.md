# 内网部署手册

把 GitLab Deployment MCP 部署到公司内网服务器，供团队成员的 Codex 通过 Streamable HTTP 接入。

## 架构

```text
同事 Codex ──HTTPS──> nginx（443，终结 TLS，可选 SSO）
                          │ 透传 Authorization 头
                          ▼
                    MCP 服务（127.0.0.1:8932，不对外）
                          │ PRIVATE-TOKEN = 当次请求的 Bearer Token
                          ▼
                    公司 GitLab（gitlab.sz.sensetime.com）
```

关键设计：

- **服务不保存 Token**：每个请求必须携带 `Authorization: Bearer <个人 GitLab Token>`，服务把它透传给 GitLab API，审计记录归属到实际调用人。
- **只能单实例运行**：MCP 会话和 scope 授权都在进程内存中，不能多副本，不能配负载均衡。
- **服务重启即失效**：所有会话和 scope 授权清空，用户下次操作时重新 `configure_project_scope` 即可，这是安全契约的一部分。

## 前提条件

- 内网 Linux 服务器，能访问 `https://gitlab.sz.sensetime.com`
- Node.js 20 或更高版本、Yarn 1.x
- 项目代码已从公司私有仓克隆到服务器（本文以 `/opt/GitLabMCP` 为例）
- 一个内网域名（本文以 `mcp.internal.company.com` 为例）和对应 TLS 证书
-  nginx 已安装

## 1. 部署服务

```bash
cd /opt/GitLabMCP
yarn install --frozen-lockfile
yarn test
```

创建专用运行账户并授权目录：

```bash
sudo useradd --system --no-create-home gitlab-mcp
sudo chown -R gitlab-mcp:gitlab-mcp /opt/GitLabMCP
```

## 2. systemd 托管

创建 `/etc/systemd/system/gitlab-mcp.service`：

```ini
[Unit]
Description=GitLab Deployment MCP
After=network.target

[Service]
Type=simple
User=gitlab-mcp
WorkingDirectory=/opt/GitLabMCP
Environment=GitLabMcpHost=127.0.0.1
Environment=GitLabMcpPort=8932
ExecStart=/usr/bin/node src/server.mjs
Restart=on-failure
RestartSec=5

# 加固项
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

注意：

- `GitLabMcpHost` 保持 `127.0.0.1`，只允许 nginx 本机转发，8932 端口不直接对外。
- **不要**在 unit 中配置 `GitLabAccessToken`——服务不读它，Token 由每个请求携带。
- `ExecStart` 中的 node 路径用 `command -v node` 的实际输出替换。

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gitlab-mcp
systemctl status gitlab-mcp
journalctl -u gitlab-mcp -f   # 应看到 listening on http://127.0.0.1:8932/mcp
```

本机验证（此时无 Token 应返回 401）：

```bash
curl -i -X POST http://127.0.0.1:8932/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# 期望：401 Unauthorized
```

## 3. nginx 反向代理

创建 `/etc/nginx/conf.d/gitlab-mcp.conf`：

```nginx
server {
    listen 443 ssl;
    server_name mcp.internal.company.com;

    ssl_certificate     /etc/nginx/certs/mcp.internal.company.com.pem;
    ssl_certificate_key /etc/nginx/certs/mcp.internal.company.com.key;

    location /mcp {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;

        # 必须透传：用户的 GitLab Token 就在这个头里
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Host $host;

        # MCP 使用 SSE 流式响应，必须关闭缓冲
        proxy_buffering off;
        proxy_cache off;

        # 长连接
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

三个配置缺一不可：

1. `proxy_set_header Authorization` —— 默认 nginx 会透传，但显式写出以防全局配置覆盖；丢了它所有请求都会 401。
2. `proxy_buffering off` —— 否则 SSE 事件被缓冲，MCP 响应会卡住或超时。
3. 长 `proxy_read_timeout` —— MCP 是长连接协议。

可选：在 nginx 前再接公司 SSO（如 oauth2-proxy 或统一网关），作为 Bearer Token 之外的第二层门禁。

### 静态托管一行安装脚本

同事的一行安装命令（见第 5 节）依赖把仓库里的 `join.ps1`（Windows）和 `join.sh`（macOS）暴露到可信 HTTPS 地址。只暴露这两个静态文件，不要代理整个仓库目录：

1. 渲染托管副本，把示例 URL 替换为真实服务地址（两个脚本在 URL 未替换时都会拒绝运行）：

```bash
sudo install -d /srv/gitlab-mcp-public
sed 's|https://mcp.internal.company.com/mcp|https://<真实域名>/mcp|' \
  /opt/GitLabMCP/join.ps1 | sudo tee /srv/gitlab-mcp-public/join.ps1 > /dev/null
sed 's|https://mcp.internal.company.com/mcp|https://<真实域名>/mcp|' \
  /opt/GitLabMCP/join.sh | sudo tee /srv/gitlab-mcp-public/join.sh > /dev/null
# <真实域名> 替换为上面 server_name 使用的域名
```

2. 在同一个 server 块中追加：

```nginx
    # 一行安装脚本：只暴露这两个静态文件
    location = /join.ps1 {
        root /srv/gitlab-mcp-public;
        default_type text/plain;
    }
    location = /join.sh {
        root /srv/gitlab-mcp-public;
        default_type text/plain;
    }
```

脚本内容不含任何秘密，可以安全公开；真正的门禁仍是 `/mcp` 的 Bearer Token。

重载并验证：

```bash
sudo nginx -t && sudo systemctl reload nginx

curl -i -X POST https://mcp.internal.company.com/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <你的 GitLab Token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"deploy-check","version":"0"}}}'
# 期望：200 + mcp-session-id 响应头 + SSE 格式的 initialize 结果

curl -s https://mcp.internal.company.com/join.ps1 | head -5
curl -s https://mcp.internal.company.com/join.sh | head -5
# 期望：脚本内容，且其中的默认 URL 已是真实地址（否则回到第 1 步重新渲染）
```

## 4. 防火墙

- 只对外开放 **443**
- **8932 不对外**：确认安全组 / iptables 没有放行该端口

```bash
# 从另一台机器验证 8932 不可达
curl -m 3 http://<服务器IP>:8932/mcp   # 期望：连接超时或拒绝
```

## 5. 同事接入

前置条件（运维）：已按第 3 节把 `join.ps1` / `join.sh` 静态托管到可信 HTTPS 地址，并把脚本默认 URL 替换为真实地址。`mcp.internal.company.com` 只是示例，不要把示例链接直接发给同事。同事侧**不需要**克隆仓库、安装 Node/Yarn 或手改配置文件。

### 5.1 一行安装（Windows，推荐）

同事在 GitLab 创建 Personal Access Token（勾选 `api` scope）后，只需在 PowerShell 中运行一行（URL 以运维通知为准）：

```powershell
irm https://mcp.internal.company.com/join.ps1 | iex
```

脚本会自动完成：

1. 提示**隐藏输入**个人 GitLab Token（输入时看不到明文），保存为当前用户环境变量 `GitLabAccessToken`；Token 不写入配置文件、不写入仓库、不回显；
2. 更新用户级 `~/.codex/config.toml` 中的 `gitlab_deployment` MCP 段，保留文件里的其他配置；
3. 可重复运行：已有 Token 不重复询问，MCP 段幂等替换，失败时明确报错退出。

完成后**完全退出并重新打开 Codex**。

写入的配置段保留全部安全契约字段（与手动配置完全一致）：

- `bearer_token_env_var = "GitLabAccessToken"` —— Token 由环境变量传入，不落盘；
- `enabled_tools` —— 只开放五个受控工具；
- `default_tools_approval_mode = "writes"` —— 写操作前必须经用户批准；
- `tool_timeout_sec = 60`。

> 为什么没有直接用 Codex 原生的 `codex mcp add <name> --url ... --bearer-token-env-var ...`：该命令只会写入 `url` 和 `bearer_token_env_var` 两个字段（已实测验证），无法表达 `enabled_tools`、`default_tools_approval_mode`、`tool_timeout_sec` 这些安全契约字段，因此脚本直接写入完整配置段，效果等价于手动配置。

### 5.2 验证接入

完全退出并重新打开 Codex，然后依次说：

1. `列出 ksa/standard-smart-office 组中的项目`
2. `这个对话只允许操作 <完整项目路径>`（确认后获得 scope）
3. `查看这个项目最近的 pipelines`

能查到 pipelines 即接入成功。

### 5.3 手动配置（排障/备用）

一行命令不可用（例如公司策略禁止远程脚本）时，按原手动方式完成同样的两件事：

1. 把 Token 设为本人用户环境变量：`setx GitLabAccessToken "<token>"`（新开终端生效）；
2. 编辑本人 `~/.codex/config.toml`，追加（不要覆盖原有配置）：

```toml
[mcp_servers.gitlab_deployment]
url = "https://mcp.internal.company.com/mcp"
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

Token 不写入配置文件，由 Codex 从环境变量读取后以 Bearer 头转发。然后完全退出并重新打开 Codex，按 5.2 验证。

### 5.4 macOS

同事在 GitLab 创建 Personal Access Token（勾选 `api` scope）后，在终端运行一行（URL 以运维通知为准）：

```bash
curl -fsSL https://mcp.internal.company.com/join.sh | bash
```

脚本会自动完成（与 Windows 的 `join.ps1` 一一对应）：

1. 提示**隐藏输入**个人 GitLab Token（脚本从 `/dev/tty` 读取，`curl | bash` 管道不影响输入），存入登录钥匙串（Keychain，`security add-generic-password`，加密落盘、重启持久）；Token 不以明文写入任何文件；
2. 向 `~/.zshrc` 追加一行从钥匙串动态取值的 `export`（可用 `JOIN_SHELL_PROFILE` 改目标文件），新开的终端会把 Token 提供给 Codex 进程；该行带 `# gitlab-mcp-join` 标记，重复运行幂等替换；
3. 更新用户级 `~/.codex/config.toml` 中的 `gitlab_deployment` MCP 段，保留文件里的其他配置，字段与 5.1 完全一致。

完成后**新开一个终端（或 `source ~/.zshrc`），然后完全退出并重新打开 Codex**。注意 Codex 必须从终端启动（或继承终端环境）才能读到该环境变量。

已知边界：

- `security add-generic-password -w` 只接受命令行参数传值，Token 会在写入瞬间出现在进程参数列表中（与各类 CLI 凭据参数同级风险）；存储本身是加密的登录钥匙串。
- 重启 macOS 后登录钥匙串随登录自动解锁，新终端即可读取；如果钥匙串被锁定，首次 `security find-generic-password` 会弹系统解锁框。
- 如果同事此前已用其他方式（如 `launchctl setenv`）设置过 `GitLabAccessToken`，脚本会检测到环境变量并把它转存进钥匙串，保证新终端可继承。
- GUI 方式启动（Dock / Spotlight）的 Codex 读不到 `~/.zshrc` 里的环境变量，必须从终端启动。

一行命令不可用时，按手动方式完成同样的三件事：

```bash
security add-generic-password -U -a "$USER" -s GitLabAccessToken -w "<token>"
echo 'export GitLabAccessToken="$(security find-generic-password -s GitLabAccessToken -w 2>/dev/null)" # gitlab-mcp-join' >> ~/.zshrc
# 再按 5.3 的 TOML 段编辑 ~/.codex/config.toml
```

## 6. 升级与回滚

```bash
cd /opt/GitLabMCP
sudo -u gitlab-mcp git pull
sudo -u gitlab-mcp yarn install --frozen-lockfile
sudo -u gitlab-mcp yarn test
sudo systemctl restart gitlab-mcp
# join.ps1 / join.sh 有更新时重新渲染托管副本（命令见第 3 节）
```

回滚：`git checkout <上一个 commit>` 后重复上述步骤。重启会清空所有会话，同事侧的 Codex 会自动重连并重新确认 scope，无需通知。

## 7. 故障排查

| 现象 | 排查 |
| --- | --- |
| Codex 报 401 | 同事本机 `GitLabAccessToken` 环境变量是否设置；nginx 是否透传了 Authorization 头 |
| 工具调用报 GitLab API 401 | 该同事的 Token 失效或权限不足，让其在 GitLab 重新生成 |
| 响应卡住或超时 | nginx `proxy_buffering off` 是否生效；`proxy_read_timeout` 是否够长 |
| 服务起不来 | `journalctl -u gitlab-mcp`；端口 8932 是否被占用；node 路径是否正确 |
| 报 "confirm repositories first" | 正常现象：服务重启后 scope 清空，重新 `configure_project_scope` |
| `irm` 报 TLS 握手错误 | 老版本 PowerShell 默认协议过旧，先执行 `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'` 再重试 |
| 运行 `join.ps1` / `join.sh` 报 "still the example address" | 运维未替换示例 URL，按第 3 节重新渲染托管副本 |
| macOS 一行命令后 Codex 仍 401 | 确认已新开终端并从终端启动 Codex；`echo $GitLabAccessToken` 应有值；`security find-generic-password -s GitLabAccessToken -w` 应能取出 Token（弹解锁框属正常） |
| macOS 同事用 bash 而非 zsh | 让同事重新运行时加 `JOIN_SHELL_PROFILE=~/.bash_profile` 前缀，或按 5.4 手动方式写入对应 profile |
| 一行命令后被执行策略拦截 | 改用 `powershell -NoProfile -ExecutionPolicy Bypass -Command "irm <URL> \| iex"`，或走 5.3 手动配置 |

## 安全清单

- [ ] 服务只监听 `127.0.0.1:8932`
- [ ] 对外只有 HTTPS 443
- [ ] nginx 透传 Authorization 且关闭 SSE 缓冲
- [ ] systemd unit 中没有配置任何 Token
- [ ] 每位同事使用自己的 GitLab Token
- [ ] 仓库和服务器上不出现任何 Token 明文
- [ ] `join.ps1` / `join.sh` 只以静态文件暴露，示例 URL 已替换为真实地址
