#!/usr/bin/env bash
# Tests for join.sh (macOS one-line onboarding).
# Mirrors tests/join.test.ps1 coverage: URL guards, config rewrite semantics,
# idempotency, security-contract fields, and token hygiene. The macOS
# security(1) keychain is replaced by an injectable stub; the test never
# touches the real keychain, shell profile, or ~/.codex.
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
profile_path="$test_root/.zshrc"
fake_keychain="$test_root/keychain"
mcp_url="https://mcp.example.test/mcp"
fake_token="join-sh-test-token-$$-$RANDOM"

cleanup() {
    case "$(basename "$test_root")" in
        gitlab-mcp-join-sh.*) rm -rf "$test_root" ;;
    esac
}
trap cleanup EXIT

# --- keychain stub: emulates the security(1) interface join.sh uses ---
cat > "$test_root/security" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
store="${JOIN_FAKE_KEYCHAIN:?JOIN_FAKE_KEYCHAIN is required}"
cmd="${1:?usage: security <command>}"
shift
tab="$(printf '\t')"
case "$cmd" in
    add-generic-password)
        service=""
        password=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -s) service="$2"; shift 2 ;;
                -w) password="$2"; shift 2 ;;
                -U) shift ;;
                -a|-j|-l|-T) shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$service" ] || exit 1
        tmp="$store.tmp"
        if [ -f "$store" ]; then
            grep -v "^${service}${tab}" "$store" > "$tmp" || true
        else
            : > "$tmp"
        fi
        printf '%s%s%s\n' "$service" "$tab" "$password" >> "$tmp"
        mv "$tmp" "$store"
        ;;
    find-generic-password)
        service=""
        print=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -s) service="$2"; shift 2 ;;
                -w) print=1; shift ;;
                *) shift ;;
            esac
        done
        line="$(grep "^${service}${tab}" "$store" 2>/dev/null || true)"
        [ -n "$line" ] || exit 44
        if [ -n "$print" ]; then
            printf '%s\n' "${line#*${tab}}"
        fi
        ;;
    *)
        printf 'unsupported security command: %s\n' "$cmd" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$test_root/security"

export JOIN_SECURITY="$test_root/security"
export JOIN_FAKE_KEYCHAIN="$fake_keychain"
export JOIN_CONFIG_DIR="$config_dir"
export JOIN_SHELL_PROFILE="$profile_path"

# --- URL guards: example address, plain HTTP, quotes, whitespace rejected ---
if assert_mcp_url "$EXAMPLE_MCP_URL" 2>/dev/null; then
    fail "Example URL was accepted"
fi
if assert_mcp_url "http://mcp.example.test/mcp" 2>/dev/null; then
    fail "Plain HTTP URL was accepted"
fi
if assert_mcp_url 'https://mcp.example.test/"bad' 2>/dev/null; then
    fail "URL with a quote was accepted"
fi
if assert_mcp_url "https://mcp.example.test/has space" 2>/dev/null; then
    fail "URL with whitespace was accepted"
fi
if set_mcp_config "http://mcp.example.test/mcp" 2>/dev/null; then
    fail "set_mcp_config accepted a plain HTTP URL"
fi
[ ! -d "$config_dir" ] || fail "A rejected URL still created the config directory"

# --- new configuration from scratch ---
set_mcp_config "$mcp_url" >/dev/null
grep -qF "url = \"$mcp_url\"" "$config_path" || fail "Remote MCP URL is missing from a new configuration"
grep -q '^\[mcp_servers\.gitlab_deployment\]$' "$config_path" || fail "Managed MCP section is missing from a new configuration"

# --- existing configuration: root keys, other server, legacy + outdated managed sections ---
cat > "$config_path" <<'EOF'
model = "test-model"

[mcp_servers.other]
command = "other"

[mcp_servers.standard_smart_office_gitlab]
command = "node"
args = ["old/server.mjs"]

[mcp_servers.gitlab_deployment]
url = "https://old.example.test/mcp"
bearer_token_env_var = "GitLabAccessToken"

[features]
example = true
EOF

# repeated runs must stay idempotent
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
grep -qF 'bearer_token_env_var = "GitLabAccessToken"' "$config_path" || fail "Per-user bearer token forwarding is missing"
grep -qF 'default_tools_approval_mode = "writes"' "$config_path" || fail "Write approval mode is missing"
grep -qF 'tool_timeout_sec = 60' "$config_path" || fail "Tool timeout is missing"
for tool in configure_project_scope list_group_projects list_pipelines list_pipeline_jobs play_deploy_job; do
    grep -qF "\"$tool\"" "$config_path" || fail "Enabled tool is missing: $tool"
done
[ "$(grep -c '^\[mcp_servers\.gitlab_deployment\]$' "$config_path")" -eq 1 ] || fail "Managed MCP configuration is not idempotent"

# --- token prompt: piped value returned, empty value rejected ---
got="$(printf '%s\n' "$fake_token" | read_gitlab_token)"
[ "$got" = "$fake_token" ] || fail "read_gitlab_token did not return the piped token"
if printf '\n' | read_gitlab_token >/dev/null 2>&1; then
    fail "Empty token was accepted"
fi

# --- keychain storage through the injectable security command ---
save_gitlab_token "$fake_token"
stored="$("$JOIN_SECURITY" find-generic-password -s GitLabAccessToken -w)"
[ "$stored" = "$fake_token" ] || fail "Token was not stored in the keychain"

# repeated saves update instead of duplicating
save_gitlab_token "$fake_token"
[ "$(grep -c '^GitLabAccessToken' "$fake_keychain")" -eq 1 ] || fail "Keychain save is not idempotent"

# --- existing token detection: keychain fallback, environment precedence ---
[ "$(get_existing_token)" = "$fake_token" ] || fail "Keychain token was not detected"
got="$(GitLabAccessToken="env-token-$$" get_existing_token)"
[ "$got" = "env-token-$$" ] || fail "Environment token did not take precedence"

# --- shell profile: keychain lookup line, idempotent, never plaintext ---
set_shell_profile >/dev/null
set_shell_profile >/dev/null
[ "$(grep -c 'gitlab-mcp-join' "$profile_path")" -eq 1 ] || fail "Profile update is not idempotent"
grep -qF 'security find-generic-password -s GitLabAccessToken -w' "$profile_path" || fail "Keychain lookup is missing from the shell profile"
if grep -qF "$fake_token" "$profile_path"; then
    fail "Token was written into the shell profile"
fi

# legacy plaintext profile lines carrying the marker must be removed
printf 'export GitLabAccessToken="old-plaintext-token" # gitlab-mcp-join\n' > "$profile_path"
set_shell_profile >/dev/null
if grep -qF "old-plaintext-token" "$profile_path"; then
    fail "Legacy plaintext profile line was not removed"
fi
[ "$(grep -c 'gitlab-mcp-join' "$profile_path")" -eq 1 ] || fail "Legacy profile line was not replaced cleanly"

# --- full onboarding: hidden prompt -> keychain -> profile -> config ---
rm -f "$fake_keychain"
printf '%s\n' "$fake_token" | JOIN_MCP_URL="$mcp_url" onboard >/dev/null
stored="$("$JOIN_SECURITY" find-generic-password -s GitLabAccessToken -w)"
[ "$stored" = "$fake_token" ] || fail "Onboarding did not store the prompted token"
grep -qF "url = \"$mcp_url\"" "$config_path" || fail "Onboarding did not write the MCP configuration"
if grep -qF "$fake_token" "$config_path"; then
    fail "Token was written into the Codex configuration"
fi
if grep -qF "$fake_token" "$profile_path"; then
    fail "Token was written into the shell profile during onboarding"
fi

# --- onboarding refuses the example URL before touching anything ---
rm -f "$config_path" "$profile_path"
if printf '%s\n' "$fake_token" | JOIN_MCP_URL="$EXAMPLE_MCP_URL" onboard >/dev/null 2>&1; then
    fail "Onboarding accepted the example URL"
fi
[ ! -f "$config_path" ] || fail "A refused onboarding still wrote the config file"
[ ! -f "$profile_path" ] || fail "A refused onboarding still wrote the shell profile"

# --- environment token is persisted to the keychain so new shells inherit it ---
rm -f "$fake_keychain" "$config_path" "$profile_path"
out="$(GitLabAccessToken="$fake_token" JOIN_MCP_URL="$mcp_url" onboard)"
printf '%s' "$out" | grep -qF "stored it in the login keychain" || fail "Environment token was not persisted to the keychain"
stored="$("$JOIN_SECURITY" find-generic-password -s GitLabAccessToken -w)"
[ "$stored" = "$fake_token" ] || fail "Environment token was not saved to the keychain"

# --- already configured: existing keychain token is kept ---
out="$(JOIN_MCP_URL="$mcp_url" onboard)"
printf '%s' "$out" | grep -qF "keeping the existing value" || fail "Existing token was not detected on rerun"
[ "$(grep -c '^GitLabAccessToken' "$fake_keychain")" -eq 1 ] || fail "Rerun duplicated the keychain entry"

printf 'ok: macOS join script onboarding verified\n'
