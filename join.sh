#!/usr/bin/env bash
# One-line onboarding to the centrally hosted GitLab deployment MCP for macOS:
#   curl -fsSL <trusted-https-url>/join.sh | bash
#
# No repo clone, no Node/Yarn, no manual config.toml edit. The personal GitLab
# token is collected with hidden input, stored in the login keychain (encrypted
# at rest, reboot-persistent), and surfaced to the Codex process through a
# keychain lookup line appended to the shell profile. The token is never
# written to any file in plain text.
#
# ASCII only on purpose: the script is fetched through curl | bash.
#
# Test seams (used by tests/join.test.sh):
#   JOIN_MCP_URL        overrides the default MCP URL
#   JOIN_CONFIG_DIR     overrides ~/.codex
#   JOIN_SHELL_PROFILE  overrides ~/.zshrc
#   JOIN_SECURITY       overrides the security(1) command (keychain stub)

SERVER_NAME="gitlab_deployment"
LEGACY_SERVER_NAME="standard_smart_office_gitlab"
TOKEN_NAME="GitLabAccessToken"
KEYCHAIN_SERVICE="GitLabAccessToken"
EXAMPLE_MCP_URL="https://mcp.internal.company.com/mcp"
PROFILE_MARKER="gitlab-mcp-join"

security_cmd() {
    printf '%s' "${JOIN_SECURITY:-security}"
}

profile_path() {
    printf '%s' "${JOIN_SHELL_PROFILE:-$HOME/.zshrc}"
}

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
bearer_token_env_var = "$TOKEN_NAME"
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

read_gitlab_token() {
    local token=""
    printf 'GitLab Access Token: ' >&2
    if [ -t 0 ]; then
        IFS= read -r -s token || true
        printf '\n' >&2
    else
        IFS= read -r token || true
    fi
    if [ -z "$token" ]; then
        printf 'GitLab Access Token is required\n' >&2
        return 1
    fi
    printf '%s' "$token"
}

keychain_has_token() {
    "$(security_cmd)" find-generic-password -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1
}

# Note: security(1) accepts the item value only through -w, so the token
# appears briefly in the process argument list during this call, like any
# CLI credential flag. Storage itself is the encrypted login keychain.
save_gitlab_token() {
    local token="${1:?token is required}"
    "$(security_cmd)" add-generic-password -U -a "${JOIN_KEYCHAIN_ACCOUNT:-${USER:-user}}" -s "$KEYCHAIN_SERVICE" -w "$token" >/dev/null
}

get_existing_token() {
    if [ -n "${GitLabAccessToken:-}" ]; then
        printf '%s' "$GitLabAccessToken"
        return 0
    fi
    local stored
    if stored="$("$(security_cmd)" find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)" && [ -n "$stored" ]; then
        printf '%s' "$stored"
        return 0
    fi
    return 1
}

# Appends one idempotent line that resolves the token from the keychain when a
# new shell starts. The token itself never lands in the profile.
set_shell_profile() {
    local profile
    profile="$(profile_path)"
    mkdir -p "$(dirname "$profile")" || return 1

    local line='export GitLabAccessToken="$(security find-generic-password -s GitLabAccessToken -w 2>/dev/null)" # gitlab-mcp-join'

    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/gitlab-mcp-profile.XXXXXX")" || return 1
    if [ -f "$profile" ]; then
        grep -v "$PROFILE_MARKER" "$profile" > "$tmp" || true
    fi
    printf '%s\n' "$line" >> "$tmp"
    mv "$tmp" "$profile" || return 1
    printf 'Added a keychain lookup for GitLabAccessToken to %s\n' "$profile"
}

onboard() {
    local url="${JOIN_MCP_URL:-$EXAMPLE_MCP_URL}"
    assert_mcp_url "$url" || return 1

    local token
    if token="$(get_existing_token)" && [ -n "$token" ]; then
        if [ -n "${GitLabAccessToken:-}" ] && ! keychain_has_token; then
            save_gitlab_token "$token" || return 1
            printf 'GitLabAccessToken found in the environment; stored it in the login keychain so new shells inherit it.\n'
        else
            printf 'GitLabAccessToken is already configured for this user; keeping the existing value.\n'
        fi
    else
        token="$(read_gitlab_token)" || return 1
        save_gitlab_token "$token" || return 1
        printf 'Saved GitLabAccessToken to the login keychain. It is never written to any file in plain text.\n'
    fi

    set_shell_profile || return 1
    set_mcp_config "$url" || return 1

    printf 'Onboarding complete. Open a new terminal (or run: source %s), then quit Codex completely and reopen it to load the MCP server.\n' "$(profile_path)"
}

# Run only when executed, not when sourced by tests. With `curl | bash` the
# script itself occupies stdin, so the interactive prompt reads from /dev/tty.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    if [ -t 0 ]; then
        onboard
    else
        onboard < /dev/tty
    fi
fi
