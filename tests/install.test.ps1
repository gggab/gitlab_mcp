$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\install.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-install-$([guid]::NewGuid())"
$configDirectory = Join-Path $testRoot ".codex"
$configPath = Join-Path $configDirectory "config.toml"

try {
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

    Set-McpConfig -ConfigDirectory $configDirectory
    Set-McpConfig -ConfigDirectory $configDirectory

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
    if (-not $config.Contains('url = "http://127.0.0.1:8932/mcp"')) {
        throw "Streamable HTTP MCP URL is missing"
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
    if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-install-*") {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
