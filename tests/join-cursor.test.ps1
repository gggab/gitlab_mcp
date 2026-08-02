$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\join-cursor.ps1")

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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-cursor-join-$([guid]::NewGuid())"
$configDirectory = Join-Path $testRoot ".cursor"
$configPath = Join-Path $configDirectory "mcp.json"
$mcpUrl = "https://mcp.example.test/mcp/gitlab-deployment"

try {
    Assert-Throws { Assert-McpUrl "https://mcp.internal.company.com/mcp/gitlab-deployment" } "Example URL was accepted"
    Assert-Throws { Assert-McpUrl "http://mcp.example.test/mcp/gitlab-deployment" } "Plain HTTP URL was accepted"
    Assert-Throws { Set-CursorMcpConfig -McpUrl "http://mcp.example.test/mcp/gitlab-deployment" -ConfigDirectory $configDirectory } "Set-CursorMcpConfig accepted a plain HTTP URL"
    if (Test-Path -LiteralPath $configDirectory) {
        throw "A rejected URL still created the config directory"
    }

    Set-CursorMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if ($config.mcpServers.gitlab_deployment.url -ne $mcpUrl) {
        throw "Cursor MCP URL is missing from a new configuration"
    }

    [IO.File]::WriteAllText(
        $configPath,
        @'
{
  "editor": { "keep": true },
  "mcpServers": {
    "other": { "url": "https://other.example.test/mcp" },
    "standard_smart_office_gitlab": { "url": "https://legacy.example.test/mcp" },
    "gitlab_deployment": { "url": "https://old.example.test/mcp" }
  }
}
'@,
        [Text.UTF8Encoding]::new($false)
    )

    Set-CursorMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    Set-CursorMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json

    if (-not $config.editor.keep) {
        throw "Existing Cursor configuration was removed"
    }
    if ($config.mcpServers.other.url -ne "https://other.example.test/mcp") {
        throw "Existing Cursor MCP configuration was removed"
    }
    if ($config.mcpServers.gitlab_deployment.url -ne $mcpUrl) {
        throw "Cursor MCP URL was not updated"
    }
    if ($null -ne $config.mcpServers.PSObject.Properties["standard_smart_office_gitlab"]) {
        throw "Legacy Cursor MCP configuration was not removed"
    }
    if (@($config.mcpServers.PSObject.Properties.Name | Where-Object { $_ -eq "gitlab_deployment" }).Count -ne 1) {
        throw "Cursor MCP configuration is not idempotent"
    }
    if ([IO.File]::ReadAllText($configPath) -match "Authorization|token|secret") {
        throw "Cursor configuration contains a client credential"
    }

    [IO.File]::WriteAllText($configPath, "{ invalid json", [Text.UTF8Encoding]::new($false))
    Assert-Throws { Set-CursorMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory } "Invalid JSON configuration was accepted"
    if ([IO.File]::ReadAllText($configPath) -ne "{ invalid json") {
        throw "Invalid configuration was overwritten"
    }

    Write-Output "ok: Cursor onboarding config update verified"
}
finally {
    if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-cursor-join-*") {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
