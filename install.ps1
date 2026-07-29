[CmdletBinding()]
param(
    [string]$Workspace
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ProjectRoot = $PSScriptRoot
$script:ServerName = "standard_smart_office_gitlab"
$script:TokenName = "GitLabAccessToken"

function Set-McpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Workspace
    )

    $workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
    $serverPath = Join-Path $script:ProjectRoot "src\server.mjs"
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw "MCP server entry point not found: $serverPath"
    }

    $configDirectory = Join-Path $workspacePath ".codex"
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
  "list_group_projects",
  "list_pipelines",
  "list_pipeline_jobs",
  "play_deploy_to_26_env",
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

    $sectionPattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($script:ServerName))\]\r?\n.*?(?=^\[|\z)"
    $config = [regex]::Replace($config, $sectionPattern, "").TrimEnd()
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
    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        throw 'Specify the Codex workspace: .\install.ps1 -Workspace "C:\path\to\StandardSmartOffice"'
    }
    if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
        throw "Workspace does not exist: $Workspace"
    }

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

    Set-McpConfig -Workspace $Workspace
    Write-Output "Installation complete. Restart Codex and open the trusted workspace."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Installer
}
