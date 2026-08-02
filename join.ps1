[CmdletBinding()]
param(
    # Example address only. The deployer MUST replace this with the real HTTPS URL
    # before hosting the script; the script refuses to run while it is unchanged.
    [string]$McpUrl = "https://mcp.internal.company.com/mcp/gitlab-deployment"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ServerName = "gitlab_deployment"
$script:LegacyServerName = "standard_smart_office_gitlab"
$script:ExampleMcpUrl = "https://mcp.internal.company.com/mcp/gitlab-deployment"

function Assert-McpUrl {
    [CmdletBinding()]
    param([string]$Url)

    if ($Url -eq $script:ExampleMcpUrl) {
        throw "The MCP URL is still the example address ($($script:ExampleMcpUrl)). The deployer must replace it with the real HTTPS URL before hosting this script."
    }
    if ($Url -match '[\s"]') {
        throw "The MCP URL must not contain whitespace or quotes: $Url"
    }
    $parsed = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne "https") {
        throw "The MCP URL must be an absolute HTTPS address: $Url"
    }
}

function Set-McpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$McpUrl,
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex")
    )

    Assert-McpUrl $McpUrl

    $configPath = Join-Path $ConfigDirectory "config.toml"
    New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null

    $block = @"
[mcp_servers.$($script:ServerName)]
url = "$McpUrl"
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
"@.Trim()

    $config = if (Test-Path -LiteralPath $configPath) {
        [IO.File]::ReadAllText($configPath)
    }
    else {
        ""
    }

    foreach ($serverName in @($script:ServerName, $script:LegacyServerName)) {
        $sectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($serverName))\]\r?\n.*?(?=^\[|\z)"
        $config = [regex]::Replace($config, $sectionPattern, "").TrimEnd()
    }
    $config = if ($config) {
        "$config`r`n`r`n$block`r`n"
    }
    else {
        "$block`r`n"
    }

    [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
    Write-Output "Configured Codex MCP in $configPath"
}

function Invoke-Onboarding {
    [CmdletBinding()]
    param(
        [string]$McpUrl = $script:ExampleMcpUrl,
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex")
    )

    Set-McpConfig -McpUrl $McpUrl -ConfigDirectory $ConfigDirectory
    Write-Output "Onboarding complete. Quit Codex completely and reopen it to authorize GitLab in the browser."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Onboarding -McpUrl $McpUrl
}
