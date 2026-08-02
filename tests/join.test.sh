#!/usr/bin/env bash
# Tests for OAuth-only macOS onboarding.
set -euo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../join.sh
source "$script_dir/../join.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-mcp-join-sh.XXXXXX")"
config_dir="$test_root/.codex"
config_path="$config_dir/config.toml"
mcp_url="https://mcp.example.test/mcp/gitlab-deployment"

cleanup() {
    case "$(basename "$test_root")" in
        gitlab-mcp-join-sh.*) rm -rf "$test_root" ;;
    esac
}
trap cleanup EXIT

export JOIN_CONFIG_DIR="$config_dir"

# URL guards: example address, plain HTTP, quotes, whitespace rejected.
if assert_mcp_url "$EXAMPLE_MCP_URL" 2>/dev/null; then
    fail "Example URL was accepted"
fi
if assert_mcp_url "http://mcp.example.test/mcp/gitlab-deployment" 2>/dev/null; then
    fail "Plain HTTP URL was accepted"
fi
if assert_mcp_url 'https://mcp.example.test/"bad' 2>/dev/null; then
    fail "URL with a quote was accepted"
fi
if assert_mcp_url "https://mcp.example.test/has space" 2>/dev/null; then
    fail "URL with whitespace was accepted"
fi
if set_mcp_config "http://mcp.example.test/mcp/gitlab-deployment" 2>/dev/null; then
    fail "set_mcp_config accepted a plain HTTP URL"
fi
[ ! -d "$config_dir" ] || fail "A rejected URL still created the config directory"

# New configuration from scratch.
set_mcp_config "$mcp_url" >/dev/null
grep -qF "url = \"$mcp_url\"" "$config_path" || fail "Remote MCP URL is missing from a new configuration"
grep -q '^\[mcp_servers\.gitlab_deployment\]$' "$config_path" || fail "Managed MCP section is missing from a new configuration"
if grep -qE '^.*env_.*=' "$config_path"; then
    fail "Client credential configuration is still present"
fi

# Existing configuration: root keys, other server, legacy + outdated managed sections.
cat > "$config_path" <<'EOF'
model = "test-model"

[mcp_servers.other]
command = "other"

[mcp_servers.standard_smart_office_gitlab]
command = "node"
args = ["old/server.mjs"]

[mcp_servers.gitlab_deployment]
url = "https://old.example.test/mcp/gitlab-deployment"

[features]
example = true
EOF

# Repeated runs must stay idempotent.
set_mcp_config "$mcp_url" >/dev/null
set_mcp_config "$mcp_url" >/dev/null

grep -qF 'model = "test-model"' "$config_path" || fail "Existing root configuration was removed"
grep -q '^\[mcp_servers\.other\]$' "$config_path" || fail "Existing MCP configuration was removed"
grep -q '^\[features\]$' "$config_path" || fail "Configuration after the managed MCP section was removed"
grep -qF "url = \"$mcp_url\"" "$config_path" || fail "Remote MCP URL was not updated"
if grep -qF "old.example.test" "$config_path"; then
    fail "Outdated MCP section was not replaced"
fi
if grep -q '^\[mcp_servers\.standard_smart_office_gitlab\]$' "$config_path"; then
    fail "Legacy MCP configuration was not removed"
fi
if grep -qE '^.*env_.*=' "$config_path"; then
    fail "Client credential configuration is still present"
fi
grep -qF 'default_tools_approval_mode = "writes"' "$config_path" || fail "Write approval mode is missing"
grep -qF 'tool_timeout_sec = 60' "$config_path" || fail "Tool timeout is missing"
for tool in configure_project_scope list_group_projects list_pipelines list_pipeline_jobs play_deploy_job; do
    grep -qF "\"$tool\"" "$config_path" || fail "Enabled tool is missing: $tool"
done
[ "$(grep -c '^\[mcp_servers\.gitlab_deployment\]$' "$config_path")" -eq 1 ] || fail "Managed MCP configuration is not idempotent"

# Onboarding writes the same OAuth-only configuration without prompting for credentials.
JOIN_MCP_URL="$mcp_url" onboard >/dev/null
grep -qF "url = \"$mcp_url\"" "$config_path" || fail "Onboarding did not write the MCP configuration"
if grep -qE '^.*env_.*=' "$config_path"; then
    fail "Onboarding wrote a client credential configuration"
fi

# Onboarding refuses the example URL before touching anything.
rm -f "$config_path"
if JOIN_MCP_URL="$EXAMPLE_MCP_URL" onboard >/dev/null 2>&1; then
    fail "Onboarding accepted the example URL"
fi
[ ! -f "$config_path" ] || fail "A refused onboarding still wrote the config file"

printf 'ok: macOS OAuth onboarding verified\n'
