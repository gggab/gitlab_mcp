# 内网部署手册

将 GitLab Deployment MCP 部署到公司内网，供 Codex 通过 HTTPS 和 GitLab OAuth 使用。

## 架构

```text
Codex -- HTTPS --> nginx (443) --> MCP service (127.0.0.1:8932) --> GitLab
                              |-- /mcp/gitlab-deployment
                              |-- /oauth/
                              `-- /.well-known/
```

用户通过 Codex 的 OAuth 登录命令打开 GitLab 登录页。授权后的 access token 随请求转发给 GitLab API；服务仅在内存中保存带过期时间的哈希，用于拒绝未经 OAuth broker 签发的 Bearer 值。服务重启后，Codex 会刷新或重新授权。

## 前提

- 可访问公司 GitLab 的 Linux 服务器；
- Node.js 20+、Yarn 1.x、nginx；
- HTTPS 域名和证书，例如 `mcp.example.com`；
- 一个由平台团队管理的 GitLab Group-owned OAuth Application；
- 该 Application 的回调地址为 `https://mcp.example.com/oauth/callback`，授权 `api` scope。

## 1. 创建 GitLab Group-owned OAuth Application

OAuth Application 是服务端的客户端身份，不是某位员工的 GitLab 凭据。生产环境不要用个人账号创建；在平台或运维组中创建，并由该组 Owner 管理。

1. 进入承载 MCP 的 GitLab Group，例如 `platform`；
2. 左侧选择 **Settings > Applications**；
3. 创建 Application，填写：

| 字段 | 值 |
| --- | --- |
| Name | `GitLab Deployment MCP` |
| Redirect URI | `https://mcp.example.com/oauth/callback` |
| Scopes | `api` |

4. 保存后，将 **Application ID** 和 **Secret** 交给服务部署者。

每位 Codex 用户仍会用自己的 GitLab 账号完成 OAuth 登录，服务对 GitLab API 的操作沿用该用户原有权限。Application Secret 只用于 MCP 服务向 GitLab 交换授权码，绝不下发给用户或写入接入脚本。

若目标 Group 没有 **Settings > Applications**，请由 Group Owner 或 GitLab 管理员创建；不要为此改用个人 Application。

## 2. 安装服务

```bash
cd /opt/GitLabMCP
yarn install --frozen-lockfile
yarn test
```

创建专用运行账户并授予目录权限：

```bash
sudo useradd --system --no-create-home gitlab-mcp
sudo chown -R gitlab-mcp:gitlab-mcp /opt/GitLabMCP
sudo install -d -o gitlab-mcp -g gitlab-mcp /var/lib/gitlab-mcp
```

## 3. 配置服务配置与 systemd

将 OAuth Application 信息放入独立的 root 管理文件，而不是 unit 文件、nginx 配置或仓库：

```bash
sudo install -d -m 0750 -o root -g gitlab-mcp /etc/gitlab-mcp
sudo install -m 0640 -o root -g gitlab-mcp /dev/null /etc/gitlab-mcp/gitlab-mcp.env
sudoedit /etc/gitlab-mcp/gitlab-mcp.env
```

填写以下内容。`GitLabBaseUrl` 是 GitLab 实例根地址，不包含 `/api/v4`。

```ini
GitLabMcpHost=127.0.0.1
GitLabMcpPort=8932
GitLabMcpPublicUrl=https://mcp.example.com
GitLabBaseUrl=https://gitlab.example.com
GitLabOAuthClientId=<Group-owned Application ID>
GitLabOAuthClientSecret=<Group-owned Application Secret>
GitLabOAuthStorePath=/var/lib/gitlab-mcp/oauth-clients.json
```

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

前三个 OAuth 变量（`GitLabMcpPublicUrl`、`GitLabOAuthClientId`、`GitLabOAuthClientSecret`）缺少任意一个，服务会拒绝启动。`GitLabOAuthStorePath` 只保存 Codex 的动态客户端注册记录，不保存任何用户 GitLab 凭据。

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gitlab-mcp
systemctl status gitlab-mcp
```

## 4. 配置 nginx

创建 `/etc/nginx/conf.d/gitlab-mcp.conf`：

```nginx
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

这三个路由都是 OAuth 流程必需项。8932 端口只监听 `127.0.0.1`，不要暴露到网络。

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s https://mcp.example.com/.well-known/oauth-authorization-server
```

最后一个命令应返回 OAuth 元数据 JSON。

## 5. 托管接入脚本

将仓库中的 `join.ps1` 和 `join.sh` 渲染为真实 MCP 地址后，作为静态文件暴露：

```bash
sudo install -d /srv/gitlab-mcp-public
sed 's|https://mcp.internal.company.com/mcp/gitlab-deployment|https://mcp.example.com/mcp/gitlab-deployment|' /opt/GitLabMCP/join.ps1 | sudo tee /srv/gitlab-mcp-public/join.ps1 > /dev/null
sed 's|https://mcp.internal.company.com/mcp/gitlab-deployment|https://mcp.example.com/mcp/gitlab-deployment|' /opt/GitLabMCP/join.sh | sudo tee /srv/gitlab-mcp-public/join.sh > /dev/null
```

在同一个 nginx `server` 中追加：

```nginx
location = /join.ps1 {
    root /srv/gitlab-mcp-public;
    default_type text/plain;
}

location = /join.sh {
    root /srv/gitlab-mcp-public;
    default_type text/plain;
}
```

## 6. 团队接入与 OAuth 登录

Windows：

```powershell
irm https://mcp.example.com/join.ps1 | iex
```

macOS：

```bash
curl -fsSL https://mcp.example.com/join.sh | bash
```

脚本只更新用户级 Codex MCP 配置，并保留其他配置；不写入 GitLab Token。完全重启 Codex 后，用户在本机执行一次：

```powershell
codex mcp login gitlab_deployment
```

该命令会打开 GitLab 网页，用户以自己的账号登录并授权。完成后再启动或重启 Codex，即可调用 GitLab MCP。

## 7. 上线验收与日常维护

发布前依次验证：

```bash
sudo systemctl status gitlab-mcp
curl -fsS https://mcp.example.com/.well-known/oauth-authorization-server
curl -i -X POST https://mcp.example.com/mcp/gitlab-deployment \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

前两个命令应成功；最后一条应返回 `401`，并带 `WWW-Authenticate: Bearer resource_metadata=...`。这是未登录时的正常 OAuth 引导响应，不是服务故障。

使用一个仅含无害手动 Job 的测试项目完成一次用户登录、项目范围确认和 Job 查询。只有在确认写操作保护仍有效后，才允许真实部署项目接入。

轮换 Application Secret 时，在 GitLab 更新 Secret，再更新 `/etc/gitlab-mcp/gitlab-mcp.env`，然后执行：

```bash
sudo systemctl restart gitlab-mcp
```

## 故障排查

## 故障排查

| 现象 | 检查项 |
| --- | --- |
| 服务无法启动 | `journalctl -u gitlab-mcp`；三个必需 OAuth 变量和 Node 路径是否正确。 |
| `codex mcp login gitlab_deployment` 没有打开授权页 | 先确认该命令使用的是 `gitlab_deployment` 配置；检查 `/mcp/gitlab-deployment` 的 401 是否带 `WWW-Authenticate`，以及 `/.well-known/` 和 `/oauth/` 是否已代理。 |
| 浏览器回调失败 | OAuth App 回调地址是否与 `GitLabMcpPublicUrl` 同源且精确匹配。 |
| 响应卡住或超时 | nginx 是否关闭缓冲并配置足够长的读取超时。 |
| 提示确认项目范围 | 正常：服务重启后 scope 会清空，重新调用 `configure_project_scope`。 |
