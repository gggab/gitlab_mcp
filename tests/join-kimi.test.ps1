$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\join-kimi.ps1")

function Assert-Throws { param([scriptblock]$Action, [string]$Message) try { & $Action } catch { return }; throw $Message }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-kimi-join-$([guid]::NewGuid())"
$configDirectory = Join-Path $testRoot ".kimi-code"
$configPath = Join-Path $configDirectory "mcp.json"
$mcpUrl = "https://mcp.example.test/mcp/gitlab-deployment"
try {
    Assert-Throws { Assert-McpUrl "https://mcp.internal.company.com/mcp/gitlab-deployment" } "Example URL was accepted"
    Assert-Throws { Set-KimiMcpConfig -McpUrl "http://mcp.example.test/mcp/gitlab-deployment" -ConfigDirectory $configDirectory } "Plain HTTP URL was accepted"
    if (Test-Path -LiteralPath $configDirectory) { throw "A rejected URL still created the config directory" }
    [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
    [IO.File]::WriteAllText($configPath, @'
{"keep":true,"mcpServers":{"other":{"url":"https://other.example.test/mcp"},"standard_smart_office_gitlab":{"url":"https://legacy.example.test/mcp"}}}
'@, [Text.UTF8Encoding]::new($false))
    Set-KimiMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    Set-KimiMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if (-not $config.keep -or $config.mcpServers.other.url -ne "https://other.example.test/mcp") { throw "Existing Kimi Code configuration was removed" }
    if ($config.mcpServers.gitlab_deployment.url -ne $mcpUrl) { throw "Kimi Code MCP URL was not updated" }
    if ($null -ne $config.mcpServers.PSObject.Properties["standard_smart_office_gitlab"]) { throw "Legacy Kimi Code MCP configuration was not removed" }
    if (@($config.mcpServers.PSObject.Properties.Name | Where-Object { $_ -eq "gitlab_deployment" }).Count -ne 1) { throw "Kimi Code MCP configuration is not idempotent" }
    if ([IO.File]::ReadAllText($configPath) -match "Authorization|token|secret") { throw "Kimi Code configuration contains a client credential" }

    $userProfile = Join-Path $testRoot "user"
    $applicationData = Join-Path $testRoot "appdata"
    $desktopHome = Join-Path $applicationData "kimi-desktop\daimon-share\daimon\runtime\kimi-code\home"
    New-Item -ItemType Directory -Path $desktopHome -Force | Out-Null
    Set-InstalledKimiMcpConfigs -McpUrl $mcpUrl -UserProfile $userProfile -ApplicationData $applicationData
    foreach ($path in @((Join-Path $userProfile ".kimi-code\mcp.json"), (Join-Path $desktopHome "mcp.json"))) {
        $installedConfig = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($installedConfig.mcpServers.gitlab_deployment.url -ne $mcpUrl) { throw "Installed Kimi Code MCP configuration was not updated: $path" }
    }

    [IO.File]::WriteAllText($configPath, "{ invalid json", [Text.UTF8Encoding]::new($false))
    Assert-Throws { Set-KimiMcpConfig -McpUrl $mcpUrl -ConfigDirectory $configDirectory } "Invalid JSON configuration was accepted"
    Write-Output "ok: Kimi Code onboarding config update verified"
}
finally { if ((Split-Path $testRoot -Leaf) -like "gitlab-mcp-kimi-join-*") { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } }
