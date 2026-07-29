$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\install.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-install-$([guid]::NewGuid())"
$workspace = Join-Path $testRoot "workspace"
$configDirectory = Join-Path $workspace ".codex"
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

    Set-McpConfig -Workspace $workspace
    Set-McpConfig -Workspace $workspace

    $config = [IO.File]::ReadAllText($configPath)
    $serverPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\server.mjs")).Path.Replace("\", "/")

    if (-not $config.Contains('model = "test-model"')) {
        throw "Existing root configuration was removed"
    }
    if (-not $config.Contains("[mcp_servers.other]")) {
        throw "Existing MCP configuration was removed"
    }
    if (-not $config.Contains("[features]")) {
        throw "Configuration after the managed MCP section was removed"
    }
    if (-not $config.Contains("args = [`"$serverPath`"]")) {
        throw "MCP server path was not updated"
    }
    if (-not $config.Contains('env_vars = ["GitLabAccessToken"]')) {
        throw "GitLabAccessToken forwarding is missing"
    }
    if (-not $config.Contains('default_tools_approval_mode = "writes"')) {
        throw "Write approval mode is missing"
    }
    if ([regex]::Matches($config, "(?m)^\[mcp_servers\.standard_smart_office_gitlab\]$").Count -ne 1) {
        throw "Managed MCP configuration is not idempotent"
    }

    Write-Output "ok: installer config update verified"
}
finally {
    if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-install-*") {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
