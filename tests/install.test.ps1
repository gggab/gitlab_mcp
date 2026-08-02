$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\install.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-install-$([guid]::NewGuid())"
$configDirectory = Join-Path $testRoot ".codex"
$configPath = Join-Path $configDirectory "config.toml"
$oauthNames = @("GitLabMcpPublicUrl", "GitLabOAuthClientId", "GitLabOAuthClientSecret")
$previousOAuthValues = @{}

try {
    foreach ($name in $oauthNames) {
        $previousOAuthValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    [Environment]::SetEnvironmentVariable("GitLabMcpPublicUrl", "https://mcp.example.test/", "Process")
    [Environment]::SetEnvironmentVariable("GitLabOAuthClientId", "test-client-id", "Process")
    [Environment]::SetEnvironmentVariable("GitLabOAuthClientSecret", "test-client-secret", "Process")
    if ((Get-OAuthMcpUrl) -ne "https://mcp.example.test/mcp/gitlab-deployment") {
        throw "OAuth public URL was not converted to the MCP URL"
    }

    New-Item -ItemType Directory -Path $configDirectory | Out-Null
    [IO.File]::WriteAllText(
        $configPath,
        @'
model = "test-model"

[mcp_servers.other]
command = "other"

[mcp_servers.standard_smart_office_gitlab]
command = "node"
args = ["old/server.mjs"]

[features]
example = true
'@,
        [Text.UTF8Encoding]::new($false)
    )

    $mcpUrl = "https://mcp.example.test/mcp/gitlab-deployment"
    Set-McpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    Set-McpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory

    $config = [IO.File]::ReadAllText($configPath)

    if (-not $config.Contains('model = "test-model"')) {
        throw "Existing root configuration was removed"
    }
    if (-not $config.Contains("[mcp_servers.other]")) {
        throw "Existing MCP configuration was removed"
    }
    if (-not $config.Contains("[features]")) {
        throw "Configuration after the managed MCP section was removed"
    }
    if (-not $config.Contains("url = `"$mcpUrl`"")) {
        throw "OAuth MCP URL is missing"
    }
    if ($config -match "(?m)^.*env_.*=") {
        throw "Client credential configuration is still present"
    }
    if ($config.Contains("command = `"node`"") -or $config.Contains("env_vars")) {
        throw "Legacy stdio configuration is still present"
    }
    if ($config.Contains("GitLabGroupPath") -or $config.Contains("GitLabDeployJobName")) {
        throw "Repository scope is still fixed in global configuration"
    }
    if (-not $config.Contains('default_tools_approval_mode = "writes"')) {
        throw "Write approval mode is missing"
    }
    if (-not $config.Contains('"play_deploy_job"')) {
        throw "Generic deployment tool is missing"
    }
    if (-not $config.Contains('"configure_project_scope"')) {
        throw "Conversation scope tool is missing"
    }
    if ([regex]::Matches($config, "(?m)^\[mcp_servers\.gitlab_deployment\]$").Count -ne 1) {
        throw "Managed MCP configuration is not idempotent"
    }
    if ($config.Contains("[mcp_servers.standard_smart_office_gitlab]")) {
        throw "Legacy MCP configuration was not removed"
    }

    Write-Output "ok: installer config update verified"
}
finally {
    foreach ($name in $oauthNames) {
        [Environment]::SetEnvironmentVariable($name, $previousOAuthValues[$name], "Process")
    }
    if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-install-*") {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
