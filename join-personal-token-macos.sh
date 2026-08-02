#!/usr/bin/env bash
# One-command macOS setup for all supported clients in personal-token mode.
set -euo pipefail

SERVER_NAME="gitlab_deployment"
LEGACY_SERVER_NAME="standard_smart_office_gitlab"
TOKEN_ENV="GITLAB_MCP_ACCESS_TOKEN"
EXAMPLE_MCP_URL="http://mcp.internal.company.com/mcp/gitlab-deployment"
SERVICE_NAME="GitLabMCP.AccessToken"
LABEL="com.gitlab-mcp.personal-token"
SUPPORT_DIR="$HOME/Library/Application Support/GitLabMCP"
HELPER_PATH="$SUPPORT_DIR/load-personal-token.sh"
AGENT_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

usage() {
    printf 'Usage: %s --url http://<internal-ip>:8932/mcp/gitlab-deployment | --remove\n' "$0" >&2
    exit 2
}

remove() {
    /bin/launchctl unsetenv "$TOKEN_ENV" || true
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$AGENT_PATH" 2>/dev/null || true
    /bin/rm -f "$AGENT_PATH" "$HELPER_PATH"
    /usr/bin/security delete-generic-password -a "$(/usr/bin/id -un)" -s "$SERVICE_NAME" 2>/dev/null || true
    printf 'Removed the GitLab MCP personal-token LaunchAgent and Keychain item.\n'
}

if [ "${1:-}" = "--remove" ] && [ "$#" -eq 1 ]; then remove; exit 0; fi
if [ "$#" -eq 0 ]; then MCP_URL="$EXAMPLE_MCP_URL"; elif [ "${1:-}" = "--url" ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ]; then MCP_URL="$2"; else usage; fi
if [ "$(/usr/bin/uname)" != "Darwin" ]; then
    printf 'This script only supports macOS.\n' >&2
    exit 1
fi
case "$MCP_URL" in
    http://?* | https://?*) ;;
    *) printf 'MCP URL must be an absolute HTTP or HTTPS address.\n' >&2; exit 1 ;;
esac
case "$MCP_URL" in *[[:space:]]* | *\"*) printf 'MCP URL must not contain whitespace or quotes.\n' >&2; exit 1 ;; esac
if [ "$MCP_URL" = "$EXAMPLE_MCP_URL" ]; then printf 'The deployer must replace the example MCP URL before hosting this script.\n' >&2; exit 1; fi

read -r -s -p 'GitLab Personal Access Token: ' token
printf '\n'
if [ -z "$token" ]; then printf 'A GitLab Personal Access Token is required.\n' >&2; exit 1; fi
/usr/bin/security add-generic-password -U -a "$(/usr/bin/id -un)" -s "$SERVICE_NAME" -w "$token"
unset token

/usr/bin/install -d -m 700 "$SUPPORT_DIR" "$HOME/Library/LaunchAgents"
temporary_helper="$(/usr/bin/mktemp "$SUPPORT_DIR/load-personal-token.XXXXXX")"
cat > "$temporary_helper" <<'SH'
#!/bin/sh
set -eu
token="$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s "GitLabMCP.AccessToken" -w)"
exec /bin/launchctl setenv GITLAB_MCP_ACCESS_TOKEN "$token"
SH
/bin/chmod 700 "$temporary_helper"
/bin/mv -f "$temporary_helper" "$HELPER_PATH"

temporary_agent="$(/usr/bin/mktemp "$HOME/Library/LaunchAgents/$LABEL.XXXXXX")"
cat > "$temporary_agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$HELPER_PATH</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
/usr/bin/plutil -lint "$temporary_agent" >/dev/null
/bin/chmod 600 "$temporary_agent"
/bin/mv -f "$temporary_agent" "$AGENT_PATH"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$AGENT_PATH" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$AGENT_PATH"
"$HELPER_PATH"

set_codex_config() {
    local config_dir="$HOME/.codex"
    local config_path="$config_dir/config.toml"
    /usr/bin/install -d -m 700 "$config_dir"
    local block
    block="$(cat <<EOF
[mcp_servers.$SERVER_NAME]
url = "$MCP_URL"
bearer_token_env_var = "$TOKEN_ENV"
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
EOF
)"
    local existing=""
    [ -f "$config_path" ] && existing="$(cat "$config_path")"
    local stripped
    stripped="$(printf '%s\n' "$existing" | awk '
        /^\[mcp_servers\.gitlab_deployment\][[:space:]]*$/ { skip = 1; next }
        /^\[mcp_servers\.standard_smart_office_gitlab\][[:space:]]*$/ { skip = 1; next }
        /^\[/ { skip = 0 }
        !skip { print }
    ' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
    local temporary
    temporary="$(/usr/bin/mktemp "$config_dir/config.toml.XXXXXX")"
    if [ -n "$stripped" ]; then printf '%s\n\n%s\n' "$stripped" "$block" > "$temporary"; else printf '%s\n' "$block" > "$temporary"; fi
    /bin/mv -f "$temporary" "$config_path"
}

set_json_configs() {
    local temporary
    temporary="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gitlab-mcp-personal-token.XXXXXX.js")"
    cat > "$temporary" <<'JXA'
ObjC.import('Foundation');
const args = $.NSProcessInfo.processInfo.arguments;
const cursorPath = ObjC.unwrap(args.objectAtIndex(4));
const kimiPath = ObjC.unwrap(args.objectAtIndex(5));
const mcpUrl = ObjC.unwrap(args.objectAtIndex(6));
const serverName = ObjC.unwrap(args.objectAtIndex(7));
const legacyServerName = ObjC.unwrap(args.objectAtIndex(8));
const fileManager = $.NSFileManager.defaultManager;
function update(path, entry) {
  const parent = ObjC.unwrap($(path).stringByDeletingLastPathComponent);
  fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(parent, true, null, null);
  let config = {};
  if (fileManager.fileExistsAtPath(path)) {
    const data = $.NSData.dataWithContentsOfFile(path);
    config = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
  }
  if (config === null || Array.isArray(config) || typeof config !== 'object') throw new Error(`${path} must be a JSON object`);
  if (!Object.prototype.hasOwnProperty.call(config, 'mcpServers')) config.mcpServers = {};
  if (config.mcpServers === null || Array.isArray(config.mcpServers) || typeof config.mcpServers !== 'object') throw new Error(`${path} mcpServers must be a JSON object`);
  delete config.mcpServers[serverName];
  delete config.mcpServers[legacyServerName];
  config.mcpServers[serverName] = entry;
  if (!$(JSON.stringify(config, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) throw new Error(`Unable to write ${path}`);
}
update(cursorPath, { url: mcpUrl, headers: { Authorization: 'Bearer ${env:GITLAB_MCP_ACCESS_TOKEN}' } });
update(kimiPath, { url: mcpUrl, bearerTokenEnvVar: 'GITLAB_MCP_ACCESS_TOKEN' });
JXA
    /usr/bin/osascript -l JavaScript "$temporary" "$HOME/.cursor/mcp.json" "$HOME/.kimi-code/mcp.json" "$MCP_URL" "$SERVER_NAME" "$LEGACY_SERVER_NAME"
    /bin/rm -f "$temporary"
}

set_codex_config
set_json_configs
if command -v claude >/dev/null 2>&1; then
    claude mcp add-json --scope user "$SERVER_NAME" "{\"type\":\"http\",\"url\":\"$MCP_URL\",\"headers\":{\"Authorization\":\"Bearer \${$TOKEN_ENV}\"}}"
else
    printf 'Claude Code is not installed; skipped its configuration. Run this script again after installing it.\n' >&2
fi
printf 'Configured personal-token MCP for Codex, Cursor, Kimi Code, and installed Claude Code. Restart each client.\n'
