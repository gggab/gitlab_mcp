#!/usr/bin/env bash
set -euo pipefail

SERVER_NAME="gitlab_deployment"
LEGACY_SERVER_NAME="standard_smart_office_gitlab"
EXAMPLE_MCP_URL="https://mcp.internal.company.com/mcp/gitlab-deployment"

assert_mcp_url() {
    local url="${1:?MCP URL is required}"
    if [ "$url" = "$EXAMPLE_MCP_URL" ]; then
        printf 'The MCP URL is still the example address (%s). The deployer must replace it with the real HTTPS URL before hosting this script.\n' "$EXAMPLE_MCP_URL" >&2
        return 1
    fi
    case "$url" in
        *[[:space:]]* | *\"*) printf 'The MCP URL must not contain whitespace or quotes: %s\n' "$url" >&2; return 1 ;;
    esac
    case "$url" in
        https://?*) ;;
        *) printf 'The MCP URL must be an absolute HTTPS address: %s\n' "$url" >&2; return 1 ;;
    esac
}

set_kimi_mcp_config() {
    local url="${1:?MCP URL is required}"
    assert_mcp_url "$url" || return 1
    local config_dir="${JOIN_KIMI_CONFIG_DIR:-$HOME/.kimi-code}"
    local config_path="$config_dir/mcp.json"
    local script_path
    script_path="$(mktemp "${TMPDIR:-/tmp}/gitlab-mcp-kimi.XXXXXX")" || return 1
    mkdir -p "$config_dir" || { rm -f "$script_path"; return 1; }

    cat > "$script_path" <<'JXA'
ObjC.import('Foundation');
const args = $.NSProcessInfo.processInfo.arguments;
const configPath = ObjC.unwrap(args.objectAtIndex(4));
const mcpUrl = ObjC.unwrap(args.objectAtIndex(5));
const serverName = ObjC.unwrap(args.objectAtIndex(6));
const legacyServerName = ObjC.unwrap(args.objectAtIndex(7));
const fileManager = $.NSFileManager.defaultManager;
let config = {};
if (fileManager.fileExistsAtPath(configPath)) {
  const data = $.NSData.dataWithContentsOfFile(configPath);
  config = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
}
if (config === null || Array.isArray(config) || typeof config !== 'object') throw new Error('Kimi Code MCP configuration must be a JSON object');
if (!Object.prototype.hasOwnProperty.call(config, 'mcpServers')) config.mcpServers = {};
if (config.mcpServers === null || Array.isArray(config.mcpServers) || typeof config.mcpServers !== 'object') throw new Error('Kimi Code MCP configuration mcpServers must be a JSON object');
delete config.mcpServers[serverName];
delete config.mcpServers[legacyServerName];
config.mcpServers[serverName] = { url: mcpUrl };
const output = $(JSON.stringify(config, null, 2) + '\n');
if (!output.writeToFileAtomicallyEncodingError(configPath, true, $.NSUTF8StringEncoding, null)) throw new Error(`Unable to write Kimi Code MCP configuration: ${configPath}`);
JXA

    if ! /usr/bin/osascript -l JavaScript "$script_path" "$config_path" "$url" "$SERVER_NAME" "$LEGACY_SERVER_NAME"; then rm -f "$script_path"; return 1; fi
    rm -f "$script_path"
    printf 'Configured Kimi Code MCP in %s\n' "$config_path"
}

onboard() {
    set_kimi_mcp_config "${JOIN_KIMI_MCP_URL:-$EXAMPLE_MCP_URL}"
    printf "Onboarding complete. Open Kimi Code, then run '/mcp-config login gitlab_deployment' to authorize GitLab in the browser.\n"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then onboard; fi
