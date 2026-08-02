[CmdletBinding()]
param(
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

function Read-KimiConfig {
    [CmdletBinding()]
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return [pscustomobject]@{}
    }
    try {
        $config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    }
    catch {
        throw "Kimi Code MCP configuration is not valid JSON: $ConfigPath"
    }
    if ($config -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Kimi Code MCP configuration must be a JSON object: $ConfigPath"
    }
    return $config
}

function Set-KimiMcpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$McpUrl,
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".kimi-code")
    )

    Assert-McpUrl $McpUrl
    $configPath = Join-Path $ConfigDirectory "mcp.json"
    $config = Read-KimiConfig -ConfigPath $configPath
    $mcpServersProperty = $config.PSObject.Properties["mcpServers"]
    if ($null -eq $mcpServersProperty) {
        $mcpServers = [pscustomobject]@{}
        $config | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue $mcpServers
    }
    else {
        $mcpServers = $mcpServersProperty.Value
        if ($mcpServers -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Kimi Code MCP configuration mcpServers must be a JSON object: $configPath"
        }
    }

    foreach ($serverName in @($script:ServerName, $script:LegacyServerName)) {
        if ($null -ne $mcpServers.PSObject.Properties[$serverName]) {
            $mcpServers.PSObject.Properties.Remove($serverName)
        }
    }
    $mcpServers | Add-Member -NotePropertyName $script:ServerName -NotePropertyValue ([pscustomobject]@{ url = $McpUrl })

    New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
    $temporaryPath = "$configPath.$([guid]::NewGuid()).tmp"
    try {
        $json = $config | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($temporaryPath, "$json`r`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    Write-Output "Configured Kimi Code MCP in $configPath"
}

function Invoke-Onboarding {
    [CmdletBinding()]
    param(
        [string]$McpUrl = $script:ExampleMcpUrl,
        [string]$ConfigDirectory = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".kimi-code")
    )

    Set-KimiMcpConfig -McpUrl $McpUrl -ConfigDirectory $ConfigDirectory
    Write-Output "Onboarding complete. Open Kimi Code, then run '/mcp-config login gitlab_deployment' to authorize GitLab in the browser."
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Onboarding -McpUrl $McpUrl
}
