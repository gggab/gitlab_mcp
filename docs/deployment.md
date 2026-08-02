# 服务端部署：GitLab OAuth

OAuth 是默认模式，适合有 HTTPS 地址、供多人使用的正式环境。每位用户通过浏览器登录 GitLab，服务端不要求用户创建 Personal Access Token。

如果明确不使用 OAuth，请改看[服务端部署：Personal Access Token](personal-token.md)。两种模式互斥，不能在同一个服务进程中混用。

## 认证链路

```text
Codex / Cursor / Claude Code / Kimi Code
                    |
                    | HTTPS + OAuth access token
                    v
nginx ──> GitLab Deployment MCP ──> GitLab REST API
  |          |
  |          `─ OAuth broker：DCR、PKCE、授权码和刷新令牌转发
  |
  `─ 对外暴露 /mcp/gitlab-deployment、/oauth/、/.well-known/
```

平台只创建一个 GitLab OAuth Application。每位用户仍以自己的 GitLab 账号授权，最终权限取决于该用户在 GitLab 中已有的权限。

## 部署前准备

本文使用以下示例值，部署时全部替换为真实值：

| 配置 | 示例 |
| --- | --- |
| MCP 公开地址 | `https://mcp.example.com` |
| GitLab 根地址 | `https://gitlab.example.com` |
| 安装目录 | `/opt/GitLabMCP` |
| 运行账户 | `gitlab-mcp` |
| 本机监听 | `127.0.0.1:8932` |

服务器需要 Node.js 20+、Yarn 1.x、nginx 和可信 HTTPS 证书。

## 1. 创建 GitLab OAuth Application

在负责该服务的平台或运维 Group 中，由 Group Owner 打开 **Settings > Applications** 并创建应用：

| 字段 | 值 |
| --- | --- |
| Name | `GitLab Deployment MCP` |
| Redirect URI | `https://mcp.example.com/oauth/callback` |
| Scopes | `api` |

回调地址必须与 MCP 公开地址同源，并精确以 `/oauth/callback` 结尾。保存 Application ID 和 Secret；Secret 只放在服务端，不能进入仓库、nginx 配置、客户端配置或接入脚本。

## 2. 准备服务文件

```bash
sudo useradd --system --no-create-home gitlab-mcp
sudo install -d -o gitlab-mcp -g gitlab-mcp /opt/GitLabMCP
sudo install -d -o gitlab-mcp -g gitlab-mcp /var/lib/gitlab-mcp
```

将仓库内容发布到 `/opt/GitLabMCP` 后安装并验证：

```bash
sudo chown -R gitlab-mcp:gitlab-mcp /opt/GitLabMCP
cd /opt/GitLabMCP
sudo -u gitlab-mcp yarn install --frozen-lockfile
sudo -u gitlab-mcp yarn test
```

测试使用假 GitLab，不会访问真实项目或触发部署。

## 3. 配置 OAuth 服务

创建仅 root 和运行组可读的环境文件：

```bash
sudo install -d -m 0750 -o root -g gitlab-mcp /etc/gitlab-mcp
sudo install -m 0640 -o root -g gitlab-mcp /dev/null /etc/gitlab-mcp/gitlab-mcp.env
sudoedit /etc/gitlab-mcp/gitlab-mcp.env
```

写入：

```ini
GitLabMcpAuthMode=oauth
GitLabMcpHost=127.0.0.1
GitLabMcpPort=8932

GitLabMcpPublicUrl=https://mcp.example.com
GitLabOAuthClientId=<Application ID>
GitLabOAuthClientSecret=<Application Secret>
GitLabOAuthStorePath=/var/lib/gitlab-mcp/oauth-clients.json

GitLabBaseUrl=https://gitlab.example.com
GitLabApiUrl=https://gitlab.example.com/api/v4
```

各变量作用如下：

| 变量 | 是否必需 | 作用 |
| --- | --- | --- |
| `GitLabMcpAuthMode` | 否 | 默认就是 `oauth`；显式设置便于审计。 |
| `GitLabMcpHost` / `GitLabMcpPort` | 否 | 默认 `127.0.0.1:8932`。 |
| `GitLabMcpPublicUrl` | 是 | MCP 的 HTTPS 基地址，不包含 `/mcp/...`。 |
| `GitLabOAuthClientId` / `GitLabOAuthClientSecret` | 是 | GitLab OAuth Application 凭据。 |
| `GitLabOAuthStorePath` | 否 | 持久化 MCP 客户端的 DCR 注册记录；不保存用户 Token。 |
| `GitLabBaseUrl` | 目标 GitLab 非默认值时 | GitLab 根地址，供 `/oauth/authorize` 和 `/oauth/token` 使用。 |
| `GitLabApiUrl` | 目标 GitLab 非默认值时 | GitLab REST API 地址，必须包含 `/api/v4`。 |

`GitLabBaseUrl` 与 `GitLabApiUrl` 用途不同；只设置前者不会改变项目、Pipeline 和 Job 请求的 API 地址。

缺少 `GitLabMcpPublicUrl`、`GitLabOAuthClientId` 或 `GitLabOAuthClientSecret` 时，OAuth 模式会拒绝启动。

## 4. 创建 systemd 服务

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
ReadWritePaths=/var/lib/gitlab-mcp

[Install]
WantedBy=multi-user.target
```

`ReadWritePaths` 对应 `GitLabOAuthStorePath`。如果不配置持久化 DCR 文件，可同时删除这两项。

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gitlab-mcp
sudo systemctl status gitlab-mcp
```

## 5. 配置 nginx

创建 `/etc/nginx/conf.d/gitlab-mcp.conf`：

```nginx
server {
    listen 80;
    server_name mcp.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name mcp.example.com;

    ssl_certificate     /etc/nginx/certs/mcp.example.com.pem;
    ssl_certificate_key /etc/nginx/certs/mcp.example.com.key;

    location = /mcp/gitlab-deployment {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Host $host;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /oauth/ {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_buffering off;
    }

    location /.well-known/ {
        proxy_pass http://127.0.0.1:8932;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
}
```

OAuth 模式必须同时代理 `/mcp/gitlab-deployment`、`/oauth/` 和 `/.well-known/`。Node 服务继续只监听 `127.0.0.1`，不要直接暴露 8932 端口。

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 6. 上线验收

先验证服务和 OAuth 元数据：

```bash
sudo systemctl status gitlab-mcp
curl -fsS https://mcp.example.com/.well-known/oauth-authorization-server
curl -fsS https://mcp.example.com/.well-known/oauth-protected-resource
```

再验证未登录请求：

```bash
curl -i -X POST https://mcp.example.com/mcp/gitlab-deployment \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

应返回 `401`，并带有 `WWW-Authenticate: Bearer resource_metadata="..."`。这是客户端发现 OAuth 登录入口的正常响应。

最后使用测试账号完成一次浏览器授权和只读查询。不要用上线验收触发真实部署 Job。

## 7. 用户接入

服务端只需向用户提供 MCP 地址：

```text
https://mcp.example.com/mcp/gitlab-deployment
```

仓库内的 OAuth 接入脚本只写入该 URL，不保存用户 Token。部署方先替换脚本中的示例 URL，再通过 HTTPS 托管：

```bash
sudo install -d /srv/gitlab-mcp-public
for file in join.ps1 join.sh join-cursor.ps1 join-cursor.sh join-kimi.ps1 join-kimi.sh; do
  sed 's|https://mcp.internal.company.com/mcp/gitlab-deployment|https://mcp.example.com/mcp/gitlab-deployment|' \
    "/opt/GitLabMCP/$file" | sudo tee "/srv/gitlab-mcp-public/$file" >/dev/null
done
```

在同一个 nginx HTTPS `server` 中增加：

```nginx
location ~ ^/(join|join-cursor|join-kimi)\.(ps1|sh)$ {
    root /srv/gitlab-mcp-public;
    default_type text/plain;
}
```

用户用 `irm https://mcp.example.com/<脚本名> | iex`（Windows）或 `curl -fsSL https://mcp.example.com/<脚本名> | bash`（macOS）执行对应脚本：

| 客户端 | 写入配置 | 完成 OAuth 登录 |
| --- | --- | --- |
| Codex | `join.ps1` 或 `join.sh` | `codex mcp login gitlab_deployment` |
| Cursor | `join-cursor.ps1` 或 `join-cursor.sh` | `cursor-agent mcp login gitlab_deployment` |
| Claude Code | `claude mcp add --transport http --scope user gitlab_deployment https://mcp.example.com/mcp/gitlab-deployment` | 启动 `claude` 后输入 `/mcp` |
| Kimi Code | `join-kimi.ps1` 或 `join-kimi.sh` | 启动 `kimi` 后输入 `/mcp-config login gitlab_deployment` |

用户完成授权后，OAuth access token 由客户端随请求携带。服务端只在内存中保留带过期时间的 Token 哈希；刷新令牌由客户端经 broker 转发到 GitLab，不会写入 `GitLabOAuthStorePath`。服务重启后，客户端会刷新或重新授权。

## 运维与故障排查

| 现象 | 处理 |
| --- | --- |
| 启动时报缺少 OAuth 配置 | 检查三个必需变量及 `EnvironmentFile` 权限。 |
| DCR 注册时报写文件失败 | 检查 `/var/lib/gitlab-mcp` 所有者和 systemd 的 `ReadWritePaths`。 |
| 浏览器回调失败 | 核对 OAuth App Redirect URI 与 `GitLabMcpPublicUrl + /oauth/callback` 是否完全一致。 |
| 客户端没有打开登录页 | 核对未登录响应中的 `WWW-Authenticate`，并确认 nginx 已代理 `/oauth/` 和 `/.well-known/`。 |
| 登录成功但 GitLab API 请求到了错误实例 | 检查 `GitLabApiUrl`；它必须指向目标实例的 `/api/v4`。 |
| 服务重启后要求重新确认项目范围 | 正常；项目 scope 仅保存在进程内存中。 |

轮换 Application Secret 时，先在 GitLab 更新 Secret，再更新环境文件并执行 `sudo systemctl restart gitlab-mcp`。
