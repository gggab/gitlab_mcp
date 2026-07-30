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

重载并验证：

```bash
sudo nginx -t && sudo systemctl reload nginx

curl -i -X POST https://mcp.internal.company.com/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <你的 GitLab Token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"deploy-check","version":"0"}}}'
# 期望：200 + mcp-session-id 响应头 + SSE 格式的 initialize 结果
```

## 4. 防火墙

- 只对外开放 **443**
- **8932 不对外**：确认安全组 / iptables 没有放行该端口

```bash
# 从另一台机器验证 8932 不可达
curl -m 3 http://<服务器IP>:8932/mcp   # 期望：连接超时或拒绝
```

## 5. 同事接入

每位同事在自己的电脑上：

### 5.1 准备个人 GitLab Token

在 GitLab 创建 Personal Access Token（勾选 `api` scope），设置为本人环境变量 `GitLabAccessToken`：

- Windows：`install.ps1` 会引导隐藏输入并写入用户环境变量；或手动 `setx GitLabAccessToken "<token>"`（新开终端生效）
- macOS：`launchctl setenv GitLabAccessToken "<token>"`

每人必须用自己的 Token，不要共享。

### 5.2 配置 Codex

编辑本人 `~/.codex/config.toml`，追加：

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

Token 不写入配置文件，由 Codex 从环境变量读取后以 Bearer 头转发。

### 5.3 重启 Codex 并验证

完全退出并重新打开 Codex，然后依次说：

1. `列出 ksa/standard-smart-office 组中的项目`
2. `这个对话只允许操作 <完整项目路径>`（确认后获得 scope）
3. `查看这个项目最近的 pipelines`

能查到 pipelines 即接入成功。

## 6. 升级与回滚

```bash
cd /opt/GitLabMCP
sudo -u gitlab-mcp git pull
sudo -u gitlab-mcp yarn install --frozen-lockfile
sudo -u gitlab-mcp yarn test
sudo systemctl restart gitlab-mcp
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

## 安全清单

- [ ] 服务只监听 `127.0.0.1:8932`
- [ ] 对外只有 HTTPS 443
- [ ] nginx 透传 Authorization 且关闭 SSE 缓冲
- [ ] systemd unit 中没有配置任何 Token
- [ ] 每位同事使用自己的 GitLab Token
- [ ] 仓库和服务器上不出现任何 Token 明文
