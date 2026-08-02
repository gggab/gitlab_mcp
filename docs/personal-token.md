# 服务端部署：Personal Access Token

Personal Token 模式不使用 OAuth App。每位用户在本机保存自己的 GitLab Personal Access Token（PAT），客户端把它作为 `Authorization: Bearer` 发送给 MCP，MCP 再转发给 GitLab REST API。服务端不保存用户 Token。

这是与 OAuth 互斥的独立模式。能提供 HTTPS 且希望统一浏览器登录时，优先使用[服务端部署：GitLab OAuth](deployment.md)。

> PAT 是 Bearer 凭据。通过 HTTP 传输时，能监听或篡改网络流量的人可以取得 Token。生产环境应使用 HTTPS；只有在隔离且可信的受限内网中，才应接受纯 HTTP 风险。

## 认证链路

```text
用户本机安全存储 / 环境变量 GITLAB_MCP_ACCESS_TOKEN
                    |
                    | Authorization: Bearer <PAT>
                    v
Codex / Cursor / Claude Code / Kimi Code
                    |
                    v
nginx ──> GitLab Deployment MCP ──> GitLab REST API
```

MCP 只检查请求是否携带 Bearer 值；真正的 Token 有效性、`api` scope 和项目权限由 GitLab 在工具访问 API 时判断。

## 部署前准备

本文使用以下示例值，部署时替换为真实值：

| 配置 | HTTPS 示例 | 无证书的受限内网示例 |
| --- | --- | --- |
| MCP 地址 | `https://mcp.internal.example.com` | `http://10.20.30.40` |
| GitLab API | `https://gitlab.example.com/api/v4` | `http://gitlab.internal/api/v4` |
| 安装目录 | `/opt/GitLabMCP` | 同左 |
| 本机监听 | `127.0.0.1:8932` | 同左 |

服务器需要 Node.js 20+、Yarn 1.x 和 nginx。每位用户需要自己的 GitLab PAT，并至少勾选 `api` scope、设置过期时间。Token 的实际权限仍受该用户 GitLab 权限限制。

## 1. 准备服务文件

```bash
sudo useradd --system --no-create-home gitlab-mcp
sudo install -d -o gitlab-mcp -g gitlab-mcp /opt/GitLabMCP
```

将仓库内容发布到 `/opt/GitLabMCP` 后安装并验证：

```bash
sudo chown -R gitlab-mcp:gitlab-mcp /opt/GitLabMCP
cd /opt/GitLabMCP
sudo -u gitlab-mcp yarn install --frozen-lockfile
sudo -u gitlab-mcp yarn test
```

测试使用假 GitLab，不会访问真实项目或触发部署。

## 2. 配置 Personal Token 服务

创建环境文件：

```bash
sudo install -d -m 0750 -o root -g gitlab-mcp /etc/gitlab-mcp
sudo install -m 0640 -o root -g gitlab-mcp /dev/null /etc/gitlab-mcp/gitlab-mcp.env
sudoedit /etc/gitlab-mcp/gitlab-mcp.env
```

写入：

```ini
GitLabMcpAuthMode=personal-token
GitLabMcpHost=127.0.0.1
GitLabMcpPort=8932
GitLabApiUrl=https://gitlab.example.com/api/v4
```

如果 GitLab 只提供内网 HTTP，则将最后一行改为真实的 `http://.../api/v4` 地址。

关键规则：

- `GitLabApiUrl` 必须包含 `/api/v4`；`GitLabBaseUrl` 不控制 REST API 地址，在此模式中不需要设置。
- 服务端环境文件不包含任何用户 PAT。
- 不要设置 `GitLabMcpPublicUrl`、`GitLabOAuthClientId`、`GitLabOAuthClientSecret` 或 `GitLabOAuthStorePath`；服务检测到这些 OAuth 配置时会拒绝以 Personal Token 模式启动。

## 3. 创建 systemd 服务

创建 `/etc/systemd/system/gitlab-mcp.service`：

```ini
[Unit]
Description=GitLab Deployment MCP
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=gitlab-mcp
WorkingDirectory=/opt/GitLabMCP
EnvironmentFile=/etc/gitlab-mcp/gitlab-mcp.env
ExecStart=/usr/bin/node src/server.mjs
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gitlab-mcp
sudo systemctl status gitlab-mcp
```

## 4. 配置 nginx

Personal Token 模式只需要代理 MCP 路由，不需要 `/oauth/` 或 `/.well-known/`。

推荐的 HTTPS 配置：

```nginx
server {
    listen 443 ssl;
    server_name mcp.internal.example.com;

    ssl_certificate     /etc/nginx/certs/mcp.internal.example.com.pem;
    ssl_certificate_key /etc/nginx/certs/mcp.internal.example.com.key;

    location = /mcp/gitlab-deployment {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;
        proxy_set_header Authorization $http_authorization;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

如果只能使用受限内网 HTTP：

```nginx
server {
    listen 80;
    server_name 10.20.30.40;

    location = /mcp/gitlab-deployment {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;
        proxy_set_header Authorization $http_authorization;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

Node 服务继续只监听 `127.0.0.1`，不要直接暴露 8932 端口。

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 5. 准备用户接入脚本

仓库提供两个脚本：

| 平台 | 脚本 | Token 保存方式 |
| --- | --- | --- |
| Windows | `join-personal-token.ps1` | Windows 当前用户环境变量 `GITLAB_MCP_ACCESS_TOKEN` |
| macOS | `join-personal-token-macos.sh` | 登录 Keychain；LaunchAgent 登录时加载环境变量 |

两个脚本都会配置 Codex、Cursor、Kimi Code，以及本机已安装的 Claude Code。它们不会把 Token 写入 MCP 客户端配置，但 Windows 用户环境变量本身是当前用户可读取的持久化存储。

部署方必须先把脚本中的示例 MCP URL 替换为真实地址，再通过可信渠道分发。例如使用 HTTPS 地址：

```bash
sudo install -d /srv/gitlab-mcp-public
sed 's|http://mcp.internal.company.com/mcp/gitlab-deployment|https://mcp.internal.example.com/mcp/gitlab-deployment|' \
  /opt/GitLabMCP/join-personal-token.ps1 | sudo tee /srv/gitlab-mcp-public/join-personal-token.ps1 >/dev/null
sed 's|http://mcp.internal.company.com/mcp/gitlab-deployment|https://mcp.internal.example.com/mcp/gitlab-deployment|' \
  /opt/GitLabMCP/join-personal-token-macos.sh | sudo tee /srv/gitlab-mcp-public/join-personal-token-macos.sh >/dev/null
```

在同一个 nginx `server` 中增加：

```nginx
location = /join-personal-token.ps1 {
    root /srv/gitlab-mcp-public;
    default_type text/plain;
}

location = /join-personal-token-macos.sh {
    root /srv/gitlab-mcp-public;
    default_type text/plain;
}
```

如果脚本只能通过 HTTP 分发，应由管理员提供并让用户核对固定校验值；否则脚本在传输中被篡改时可直接窃取用户输入的 PAT。

## 6. 用户接入

用户先在 GitLab 创建自己的 PAT，再执行对应脚本并按提示隐藏输入 Token。

Windows：

```powershell
irm https://mcp.internal.example.com/join-personal-token.ps1 | iex
```

macOS：

```bash
curl -fsSL https://mcp.internal.example.com/join-personal-token-macos.sh | bash
```

接入后完全退出并重开客户端，使 `GITLAB_MCP_ACCESS_TOKEN` 对新进程可见。此模式不运行以下 OAuth 登录命令：

- 不运行 `codex mcp login gitlab_deployment`；
- 不运行 `cursor-agent mcp login gitlab_deployment`；
- 不在 Claude Code `/mcp` 中发起 OAuth；
- 不运行 Kimi Code `/mcp-config login gitlab_deployment`。

## 7. 上线验收

未携带 Token 的请求应返回 `401`，且不带 OAuth 的 `resource_metadata`：

```bash
curl -i -X POST https://mcp.internal.example.com/mcp/gitlab-deployment \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

然后让测试用户重启客户端，执行一次只读的项目列表查询。该查询成功才证明客户端已加载 PAT、nginx 保留了 `Authorization` 头，并且 `GitLabApiUrl` 正确。不要用上线验收触发真实部署 Job。

## Token 轮换与故障排查

用户轮换 PAT 后重新运行接入脚本并重启客户端。用户离职、设备遗失或权限变化时，应立即在 GitLab 撤销该 PAT。

| 现象 | 处理 |
| --- | --- |
| 服务启动时报 Personal Token 与 OAuth 配置冲突 | 删除服务端遗留的四个 OAuth 变量。 |
| MCP 立即返回 `401` | 客户端没有发送 Bearer 头；确认已重启并加载 `GITLAB_MCP_ACCESS_TOKEN`。 |
| 工具调用返回 GitLab `401` 或 `403` | 检查 PAT 是否过期、是否有 `api` scope，以及用户是否有目标项目权限。 |
| 请求到了错误 GitLab 或出现错误 API 路径 | 检查 `GitLabApiUrl` 是否指向目标实例并包含 `/api/v4`。 |
| Windows 更新 Token 后仍使用旧值 | 完全退出所有客户端进程再重开；已运行进程不会自动读取新的用户环境变量。 |
| macOS 不再使用此服务 | 运行托管脚本的 `--remove` 模式，并在 GitLab 撤销 PAT。 |
