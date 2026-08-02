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
grep -q 'claude mcp add-json --scope user' "$script" || fail "Claude Code configuration is missing"
printf 'ok: macOS personal-token onboarding verified\n'
