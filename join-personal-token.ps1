[CmdletBinding()]
param([string]$McpUrl = "http://mcp.internal.company.com/mcp/gitlab-deployment")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$serverName = "gitlab_deployment"
$legacyServerName = "standard_smart_office_gitlab"
$tokenEnv = "GITLAB_MCP_ACCESS_TOKEN"
$exampleUrl = "http://mcp.internal.company.com" + "/mcp/gitlab-deployment"

if ($McpUrl -eq $exampleUrl -or $McpUrl -match '[\s"]' -or $McpUrl -notmatch '^https?://') {
    throw "The deployer must replace the example MCP URL with an absolute internal HTTP or HTTPS URL before hosting this script."
}

$secureToken = Read-Host "GitLab Personal Access Token" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
if (-not $token) { throw "A GitLab Personal Access Token is required." }
[Environment]::SetEnvironmentVariable($tokenEnv, $token, "User")
$token = $null

function Update-JsonMcpConfig([string]$Path, [object]$Entry) {
    $directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    try { $config = if (Test-Path $Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } else { [pscustomobject]@{} } }
    catch { throw "Invalid MCP JSON: $Path" }
    if ($config -isnot [pscustomobject]) { throw "MCP configuration must be a JSON object: $Path" }
    if ($null -eq $config.PSObject.Properties["mcpServers"]) { $config | Add-Member NoteProperty mcpServers ([pscustomobject]@{}) }
    $servers = $config.mcpServers
    if ($servers -isnot [pscustomobject]) { throw "mcpServers must be a JSON object: $Path" }
    foreach ($name in @($serverName, $legacyServerName)) { if ($servers.PSObject.Properties[$name]) { $servers.PSObject.Properties.Remove($name) } }
    $servers | Add-Member NoteProperty $serverName $Entry
    [IO.File]::WriteAllText($Path, (($config | ConvertTo-Json -Depth 10) + "`r`n"), [Text.UTF8Encoding]::new($false))
}

$homeDirectory = [Environment]::GetFolderPath("UserProfile")
$codexPath = Join-Path $homeDirectory ".codex\config.toml"
New-Item -ItemType Directory -Force -Path (Split-Path $codexPath) | Out-Null
$existing = if (Test-Path $codexPath) { [IO.File]::ReadAllText($codexPath) } else { "" }
foreach ($name in @($serverName, $legacyServerName)) { $existing = [regex]::Replace($existing, "(?ms)^\[mcp_servers\.$([regex]::Escape($name))\]\r?\n.*?(?=^\[|\z)", "").TrimEnd() }
$block = @"
[mcp_servers.gitlab_deployment]
url = "$McpUrl"
bearer_token_env_var = "$tokenEnv"
enabled_tools = ["configure_project_scope", "list_group_projects", "list_pipelines", "list_pipeline_jobs", "play_deploy_job"]
default_tools_approval_mode = "writes"
tool_timeout_sec = 60
enabled = true
"@.Trim()
[IO.File]::WriteAllText($codexPath, $(if ($existing) { "$existing`r`n`r`n$block`r`n" } else { "$block`r`n" }), [Text.UTF8Encoding]::new($false))

Update-JsonMcpConfig (Join-Path $homeDirectory ".cursor\mcp.json") ([pscustomobject]@{ url = $McpUrl; headers = [pscustomobject]@{ Authorization = "Bearer `${env:GITLAB_MCP_ACCESS_TOKEN}" } })
Update-JsonMcpConfig (Join-Path $homeDirectory ".kimi-code\mcp.json") ([pscustomobject]@{ url = $McpUrl; bearerTokenEnvVar = $tokenEnv })
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $claudeJson = '{"type":"http","url":"' + $McpUrl + '","headers":{"Authorization":"Bearer ${GITLAB_MCP_ACCESS_TOKEN}"}}'
    & claude mcp add-json --scope user $serverName $claudeJson
}
else { Write-Warning "Claude Code is not installed; run this script again after installing it." }
Write-Output "Configured personal-token MCP for Codex, Cursor, Kimi Code, and installed Claude Code. Restart each client."
