$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "..\join-personal-token.ps1"
$content = [IO.File]::ReadAllText($script)
foreach ($expected in @("Read-Host", 'SetEnvironmentVariable($tokenEnv, $token, "User")', 'SetEnvironmentVariable($tokenEnv, $token, "Process")', "bearer_token_env_var", "GITLAB_MCP_ACCESS_TOKEN", "claude mcp add-json", '$LASTEXITCODE -ne 0')) { if ($content -notmatch [regex]::Escape($expected)) { throw "Missing $expected" } }
$placeholder = "http://mcp.internal.company.com/mcp/gitlab-deployment"
if ([regex]::Matches($content, [regex]::Escape($placeholder)).Count -ne 1) { throw "Hosted-script URL placeholder must occur exactly once" }
$rendered = $content.Replace($placeholder, "http://10.20.30.40/mcp/gitlab-deployment")
if ($rendered -notmatch '\$exampleUrl = "http://mcp\.internal\.company\.com" \+ "/mcp/gitlab-deployment"') { throw "Rendered script overwrote its example URL guard" }

. $script
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "gitlab-mcp-personal-token-$([guid]::NewGuid())"
try {
    $configPath = Join-Path $temporaryDirectory "mcp.json"
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    [IO.File]::WriteAllText($configPath, " `r`n", [Text.UTF8Encoding]::new($false))
    Update-JsonMcpConfig $configPath ([pscustomobject]@{ url = "http://mcp.test/mcp/gitlab-deployment" })
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    if ($config.mcpServers.gitlab_deployment.url -ne "http://mcp.test/mcp/gitlab-deployment") { throw "Blank MCP configuration was not initialized" }

    [IO.File]::WriteAllText($configPath, "[]", [Text.UTF8Encoding]::new($false))
    try { Update-JsonMcpConfig $configPath ([pscustomobject]@{ url = "http://mcp.test" }); throw "Non-object MCP configuration was accepted" }
    catch { if ($_.Exception.Message -notmatch "must be a JSON object") { throw } }
}
finally {
    if (Test-Path $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
}
Write-Output "ok: Windows personal-token onboarding guard verified"
