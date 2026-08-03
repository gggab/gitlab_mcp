$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "..\join-personal-token.ps1"
$content = [IO.File]::ReadAllText($script)
foreach ($expected in @("Read-Host", "SetEnvironmentVariable", "bearer_token_env_var", "GITLAB_MCP_ACCESS_TOKEN", "claude mcp add-json")) { if ($content -notmatch [regex]::Escape($expected)) { throw "Missing $expected" } }
$placeholder = "http://mcp.internal.company.com/mcp/gitlab-deployment"
if ([regex]::Matches($content, [regex]::Escape($placeholder)).Count -ne 1) { throw "Hosted-script URL placeholder must occur exactly once" }
$rendered = $content.Replace($placeholder, "http://10.20.30.40/mcp/gitlab-deployment")
if ($rendered -notmatch '\$exampleUrl = "http://mcp\.internal\.company\.com" \+ "/mcp/gitlab-deployment"') { throw "Rendered script overwrote its example URL guard" }
Write-Output "ok: Windows personal-token onboarding guard verified"
