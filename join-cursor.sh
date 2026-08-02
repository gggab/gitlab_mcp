#!/usr/bin/env bash
# One-line Cursor onboarding for macOS:
#   curl -fsSL <trusted-https-url>/join-cursor.sh | bash
#
# Uses macOS's built-in osascript to merge ~/.cursor/mcp.json. No user
# credential is requested or stored; Cursor performs OAuth separately.

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
        *[[:space:]]* | *\"*)
            printf 'The MCP URL must not contain whitespace or quotes: %s\n' "$url" >&2
            return 1
            ;;
    esac
    case "$url" in
        https://?*) ;;
        *)
            printf 'The MCP URL must be an absolute HTTPS address: %s\n' "$url" >&2
            return 1
            ;;
    esac
}

set_cursor_mcp_config() {
    local url="${1:?MCP URL is required}"
    assert_mcp_url "$url" || return 1

    local config_dir="${JOIN_CURSOR_CONFIG_DIR:-$HOME/.cursor}"
    local config_path="$config_dir/mcp.json"
    local script_path
    script_path="$(mktemp "${TMPDIR:-/tmp}/gitlab-mcp-cursor.XXXXXX.js")" || return 1

    mkdir -p "$config_dir" || {
        rm -f "$script_path"
        return 1
    }

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
  const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  config = JSON.parse(text);
}
if (config === null || Array.isArray(config) || typeof config !== 'object') {
  throw new Error('Cursor MCP configuration must be a JSON object');
}
if (!Object.prototype.hasOwnProperty.call(config, 'mcpServers')) {
  config.mcpServers = {};
}
if (config.mcpServers === null || Array.isArray(config.mcpServers) || typeof config.mcpServers !== 'object') {
  throw new Error('Cursor MCP configuration mcpServers must be a JSON object');
}

delete config.mcpServers[serverName];
delete config.mcpServers[legacyServerName];
config.mcpServers[serverName] = { url: mcpUrl };

const output = $(JSON.stringify(config, null, 2) + '\n');
const written = output.writeToFileAtomicallyEncodingError(configPath, true, $.NSUTF8StringEncoding, null);
if (!written) {
  throw new Error(`Unable to write Cursor MCP configuration: ${configPath}`);
}
JXA

    if ! /usr/bin/osascript -l JavaScript "$script_path" "$config_path" "$url" "$SERVER_NAME" "$LEGACY_SERVER_NAME"; then
        rm -f "$script_path"
        return 1
    fi
    rm -f "$script_path"
    printf 'Configured Cursor MCP in %s\n' "$config_path"
}

onboard() {
    local url="${JOIN_CURSOR_MCP_URL:-$EXAMPLE_MCP_URL}"
    set_cursor_mcp_config "$url"
    printf "Onboarding complete. Open Cursor, then run 'cursor-agent mcp login gitlab_deployment' to authorize GitLab in the browser.\n"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    onboard
fi
