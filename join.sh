#!/usr/bin/env bash
# One-line onboarding to the centrally hosted GitLab deployment MCP for macOS:
#   curl -fsSL <trusted-https-url>/join.sh | bash
#
# No repo clone, no Node/Yarn, no manual config.toml edit. Codex opens the
# browser for GitLab OAuth on first use; this script stores no user credential.
#
# ASCII only on purpose: the script is fetched through curl | bash.
#
# Test seams (used by tests/join.test.sh):
#   JOIN_MCP_URL        overrides the default MCP URL
#   JOIN_CONFIG_DIR     overrides ~/.codex

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

set_mcp_config() {
    local url="${1:?MCP URL is required}"
    assert_mcp_url "$url" || return 1

    local config_dir="${JOIN_CONFIG_DIR:-$HOME/.codex}"
    local config_path="$config_dir/config.toml"
    mkdir -p "$config_dir" || return 1

    local block
    block="$(cat <<EOF
[mcp_servers.$SERVER_NAME]
url = "$url"
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
    if [ -f "$config_path" ]; then
        existing="$(cat "$config_path")"
    fi

    # Drop the managed and legacy sections, then trim trailing blank lines.
    local stripped
    stripped="$(printf '%s\n' "$existing" | awk '
        /^\[mcp_servers\.gitlab_deployment\][[:space:]]*$/ { skip = 1; next }
        /^\[mcp_servers\.standard_smart_office_gitlab\][[:space:]]*$/ { skip = 1; next }
        /^\[/ { skip = 0 }
        !skip { print }
    ' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/gitlab-mcp-config.XXXXXX")" || return 1
    if [ -n "$stripped" ]; then
        printf '%s\n\n%s\n' "$stripped" "$block" > "$tmp"
    else
        printf '%s\n' "$block" > "$tmp"
    fi
    mv "$tmp" "$config_path" || return 1
    printf 'Configured Codex MCP in %s\n' "$config_path"
}

onboard() {
    local url="${JOIN_MCP_URL:-$EXAMPLE_MCP_URL}"
    assert_mcp_url "$url" || return 1
    set_mcp_config "$url" || return 1

    printf 'Onboarding complete. Quit Codex completely and reopen it to authorize GitLab in the browser.\n'
}

# Run only when executed, not when sourced by tests.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    onboard
fi
