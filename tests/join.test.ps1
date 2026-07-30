$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\join.ps1")

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw $Message
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-join-$([guid]::NewGuid())"
$configDirectory = Join-Path $testRoot ".codex"
$configPath = Join-Path $configDirectory "config.toml"
$mcpUrl = "https://mcp.example.test/mcp"
$fakeToken = "join-test-token-$([guid]::NewGuid())"

try {
    # URL guard: example address, plain HTTP, and embedded quotes are all rejected.
    Assert-Throws { Assert-McpUrl "https://mcp.internal.company.com/mcp" } "Example URL was accepted"
    Assert-Throws { Assert-McpUrl "http://mcp.example.test/mcp" } "Plain HTTP URL was accepted"
    Assert-Throws { Assert-McpUrl "https://mcp.example.test/`"bad" } "URL with a quote was accepted"
    Assert-Throws { Set-McpConfig -McpUrl "http://mcp.example.test/mcp" -ConfigDirectory $configDirectory } "Set-McpConfig accepted a plain HTTP URL"
    if (Test-Path -LiteralPath $configDirectory) {
        throw "A rejected URL still created the config directory"
    }

    # New configuration from scratch.
    Set-McpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    $config = [IO.File]::ReadAllText($configPath)
    if (-not $config.Contains("url = `"$mcpUrl`"")) {
        throw "Remote MCP URL is missing from a new configuration"
    }
    if (-not $config.Contains("[mcp_servers.gitlab_deployment]")) {
        throw "Managed MCP section is missing from a new configuration"
    }

    # Existing configuration: unrelated sections, a legacy section, and an outdated managed section.
    [IO.File]::WriteAllText(
        $configPath,
        @'
model = "test-model"

[mcp_servers.other]
command = "other"

[mcp_servers.standard_smart_office_gitlab]
command = "node"
args = ["old/server.mjs"]

[mcp_servers.gitlab_deployment]
url = "https://old.example.test/mcp"
bearer_token_env_var = "GitLabAccessToken"

[features]
example = true
'@,
        [Text.UTF8Encoding]::new($false)
    )

    # Repeated runs must stay idempotent.
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
        throw "Remote MCP URL was not updated"
    }
    if ($config.Contains("old.example.test")) {
        throw "Outdated MCP section was not replaced"
    }
    if ($config.Contains("[mcp_servers.standard_smart_office_gitlab]")) {
        throw "Legacy MCP configuration was not removed"
    }
    if (-not $config.Contains('bearer_token_env_var = "GitLabAccessToken"')) {
        throw "Per-user bearer token forwarding is missing"
    }
    if (-not $config.Contains('default_tools_approval_mode = "writes"')) {
        throw "Write approval mode is missing"
    }
    if (-not $config.Contains("tool_timeout_sec = 60")) {
        throw "Tool timeout is missing"
    }
    foreach ($tool in @("configure_project_scope", "list_group_projects", "list_pipelines", "list_pipeline_jobs", "play_deploy_job")) {
        if (-not $config.Contains("`"$tool`"")) {
            throw "Enabled tool is missing: $tool"
        }
    }
    if ([regex]::Matches($config, "(?m)^\[mcp_servers\.gitlab_deployment\]$").Count -ne 1) {
        throw "Managed MCP configuration is not idempotent"
    }

    # Token handling: process-scoped save for the test, never the user scope, never the config file.
    Save-GitLabToken -Token $fakeToken -Target "Process"
    if ([Environment]::GetEnvironmentVariable("GitLabAccessToken", "Process") -ne $fakeToken) {
        throw "Token was not saved to the requested scope"
    }
    if ([Environment]::GetEnvironmentVariable("GitLabAccessToken", "User") -eq $fakeToken) {
        throw "Test leaked the token into the user environment"
    }

    Set-McpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    $config = [IO.File]::ReadAllText($configPath)
    if ($config.Contains($fakeToken)) {
        throw "Token was written into the Codex configuration"
    }

    Write-Output "ok: join script config update verified"
}
finally {
    [Environment]::SetEnvironmentVariable("GitLabAccessToken", $null, "Process")
    if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-join-*") {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
