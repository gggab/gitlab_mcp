[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ProjectRoot = $PSScriptRoot
$script:ServerName = "gitlab_deployment"
$script:LegacyServerName = "standard_smart_office_gitlab"
$script:OAuthConfigNames = @(
    "GitLabMcpPublicUrl",
    "GitLabOAuthClientId",
    "GitLabOAuthClientSecret"
)

function Set-McpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$McpUrl,
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex")
    )

    $serverPath = Join-Path $script:ProjectRoot "src\server.mjs"
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw "MCP server entry point not found: $serverPath"
    }

    $configPath = Join-Path $configDirectory "config.toml"
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

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

function Get-OAuthMcpUrl {
    $values = @{}
    foreach ($name in $script:OAuthConfigNames) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if (-not $value) {
            $value = [Environment]::GetEnvironmentVariable($name, "User")
        }
        if ($value) {
            $values[$name] = $value
        }
    }

    $missing = $script:OAuthConfigNames | Where-Object { -not $values.ContainsKey($_) }
    if ($missing) {
        throw "OAuth broker configuration is required; missing: $($missing -join ', ')"
    }

    $publicUrl = $values.GitLabMcpPublicUrl.TrimEnd("/")
    $parsed = $null
    if (-not [uri]::TryCreate($publicUrl, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne "https") {
        throw "GitLabMcpPublicUrl must be an absolute HTTPS address"
    }
    return "$publicUrl/mcp/gitlab-deployment"
}

function Invoke-Installer {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw "Node.js 20 or newer is required"
    }
    $nodeVersion = & $node.Source --version
    if ([int]($nodeVersion.TrimStart("v").Split(".")[0]) -lt 20) {
        throw "Node.js 20 or newer is required; found $nodeVersion"
    }

    $yarn = Get-Command yarn.cmd -ErrorAction SilentlyContinue
    if (-not $yarn) {
        throw "Yarn is required"
    }

    $mcpUrl = Get-OAuthMcpUrl

    Push-Location $script:ProjectRoot
    try {
        & $yarn.Source install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) {
            throw "Dependency installation failed"
        }

        & $yarn.Source test
        if ($LASTEXITCODE -ne 0) {
            throw "MCP verification failed"
        }
    }
    finally {
        Pop-Location
    }

    Set-McpConfig -McpUrl $mcpUrl
    Write-Output "Installation complete. Start the MCP server with 'yarn start', then restart Codex to authorize in the browser."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Installer
}
