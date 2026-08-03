#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/join-personal-token-macos.sh"
fail() { printf 'test failed: %s\n' "$1" >&2; exit 1; }

grep -q 'read -r -s' "$script" || fail "token input is not hidden"
grep -q 'security add-generic-password' "$script" || fail "Keychain storage is missing"
grep -q 'security find-generic-password' "$script" || fail "Keychain retrieval is missing"
grep -q 'launchctl setenv GITLAB_MCP_ACCESS_TOKEN' "$script" || fail "LaunchAgent environment setup is missing"
grep -q -- '--remove' "$script" || fail "removal path is missing"
grep -q 'bearer_token_env_var' "$script" || fail "Codex bearer environment configuration is missing"
grep -q "Bearer \${env:GITLAB_MCP_ACCESS_TOKEN}" "$script" || fail "Cursor environment header is missing"
grep -q 'bearerTokenEnvVar' "$script" || fail "Kimi Code bearer environment configuration is missing"
grep -q '/usr/bin/install -d -m 700 "$HOME/.cursor" "$HOME/.kimi-code"' "$script" || fail "MCP client configuration directories are not created safely"
if grep -q 'createDirectoryAtPathWithIntermediateDirectoriesAttributesError' "$script"; then fail "JXA passes null directory attributes as NSNull"; fi
if grep -q 'XXXXXX\.js' "$script"; then fail "macOS mktemp template has a suffix after XXXXXX"; fi
grep -q 'claude mcp add --transport http --scope user' "$script" || fail "Claude Code HTTP configuration is missing"
placeholder='http://mcp.internal.company.com/mcp/gitlab-deployment'
[ "$(grep -Fo "$placeholder" "$script" | wc -l | tr -d ' ')" = "1" ] || fail "hosted-script URL placeholder must occur exactly once"
rendered="$(sed "s|$placeholder|http://10.20.30.40/mcp/gitlab-deployment|" "$script")"
printf '%s\n' "$rendered" | grep -q 'EXAMPLE_MCP_URL="http://mcp.internal.company.com""/mcp/gitlab-deployment"' || fail "rendered script overwrote its example URL guard"
printf 'ok: macOS personal-token onboarding verified\n'
