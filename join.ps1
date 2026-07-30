[CmdletBinding()]
param(
    # Example address only. The deployer MUST replace this with the real HTTPS URL
    # before hosting the script; the script refuses to run while it is unchanged.
    [string]$McpUrl = "https://mcp.internal.company.com/mcp"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ServerName = "gitlab_deployment"
$script:LegacyServerName = "standard_smart_office_gitlab"
$script:TokenName = "GitLabAccessToken"
$script:ExampleMcpUrl = "https://mcp.internal.company.com/mcp"

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
bearer_token_env_var = "$($script:TokenName)"
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

function Read-GitLabToken {
    $secureToken = Read-Host "GitLab Access Token" -AsSecureString
    if ($secureToken.Length -eq 0) {
        throw "GitLab Access Token is required"
    }

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Save-GitLabToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [ValidateSet("Process", "User")]
        [string]$Target = "User"
    )

    [Environment]::SetEnvironmentVariable($script:TokenName, $Token, "Process")
    [Environment]::SetEnvironmentVariable($script:TokenName, $Token, $Target)
}

function Get-ExistingToken {
    $token = [Environment]::GetEnvironmentVariable($script:TokenName, "Process")
    if (-not $token) {
        $token = [Environment]::GetEnvironmentVariable($script:TokenName, "User")
    }
    return $token
}

function Invoke-Onboarding {
    Assert-McpUrl $McpUrl

    $token = Get-ExistingToken
    if ($token) {
        Write-Output "GitLabAccessToken is already configured for this user; keeping the existing value."
    }
    else {
        $token = Read-GitLabToken
        Save-GitLabToken -Token $token
        Write-Output "Saved GitLabAccessToken as a user environment variable. It is never written to any file."
    }
    $token = $null

    Set-McpConfig -McpUrl $McpUrl

    Write-Output "Onboarding complete. Quit Codex completely and reopen it to load the MCP server."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Onboarding
}
