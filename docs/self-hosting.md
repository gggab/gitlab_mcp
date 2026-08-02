# 选择服务端部署方式

服务端只有两种互斥的认证模式：

- 有可信 HTTPS 地址、希望用户通过浏览器登录：使用[GitLab OAuth 部署](deployment.md)。
- 明确不使用 OAuth、由每位用户管理自己的 PAT：使用[Personal Access Token 部署](personal-token.md)。

Windows 本机运行 OAuth 服务时可以执行 `install.ps1`；它会验证 OAuth 环境变量、安装依赖、运行测试，并把公开 MCP URL 写入当前用户的 Codex 配置。Personal Token 模式不要使用该脚本。
