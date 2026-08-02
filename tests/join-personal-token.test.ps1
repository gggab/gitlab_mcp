$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "..\join-personal-token.ps1"
$content = [IO.File]::ReadAllText($script)
foreach ($expected in @("Read-Host", "SetEnvironmentVariable", "bearer_token_env_var", "GITLAB_MCP_ACCESS_TOKEN", "claude mcp add-json")) { if ($content -notmatch [regex]::Escape($expected)) { throw "Missing $expected" } }
Write-Output "ok: Windows personal-token onboarding guard verified"
