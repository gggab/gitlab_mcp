[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ProjectRoot = $PSScriptRoot
$script:ServerName = "gitlab_deployment"
$script:LegacyServerName = "standard_smart_office_gitlab"
$script:TokenName = "GitLabAccessToken"

function Set-McpConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex")
    )

    $serverPath = Join-Path $script:ProjectRoot "src\server.mjs"
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw "MCP server entry point not found: $serverPath"
    }

    $configPath = Join-Path $configDirectory "config.toml"
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

    $serverPath = $serverPath.Replace("\", "/")
    $projectRoot = $script:ProjectRoot.Replace("\", "/")
    $block = @"
[mcp_servers.$($script:ServerName)]
command = "node"
args = ["$serverPath"]
cwd = "$projectRoot"
env_vars = ["$($script:TokenName)"]
enabled_tools = [
  "configure_project_scope",
  "list_group_projects",
  "list_pipelines",
  "list_pipeline_jobs",
  "play_deploy_job",
]
default_tools_approval_mode = "writes"
startup_timeout_sec = 10
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

function Get-GitLabToken {
    $token = [Environment]::GetEnvironmentVariable($script:TokenName, "Process")
    if (-not $token) {
        $token = [Environment]::GetEnvironmentVariable($script:TokenName, "User")
    }
    if ($token) {
        return $token
    }

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

    Push-Location $script:ProjectRoot
    try {
        & $yarn.Source install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) {
            throw "Dependency installation failed"
        }

        $token = Get-GitLabToken
        $env:GitLabAccessToken = $token
        [Environment]::SetEnvironmentVariable($script:TokenName, $token, "User")
        $token = $null

        & $yarn.Source test
        if ($LASTEXITCODE -ne 0) {
            throw "MCP verification failed"
        }
    }
    finally {
        Pop-Location
    }

    Set-McpConfig
    Write-Output "Installation complete. Restart Codex."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Installer
}
