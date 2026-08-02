#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/join-cursor.sh"

fail() {
    printf 'test failed: %s\n' "$1" >&2
    exit 1
}

if assert_mcp_url "$EXAMPLE_MCP_URL" 2>/dev/null; then
    fail "example URL was accepted"
fi
if assert_mcp_url "http://mcp.example.test/mcp/gitlab-deployment" 2>/dev/null; then
    fail "plain HTTP URL was accepted"
fi
if assert_mcp_url 'https://mcp.example.test/"bad' 2>/dev/null; then
    fail "URL with a quote was accepted"
fi

grep -q '/usr/bin/osascript -l JavaScript' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/join-cursor.sh" || fail "macOS JSON writer is missing"
grep -q 'delete config.mcpServers\[legacyServerName\]' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/join-cursor.sh" || fail "legacy server cleanup is missing"
grep -q 'config.mcpServers\[serverName\] = { url: mcpUrl }' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/join-cursor.sh" || fail "Cursor URL configuration is missing"

printf 'ok: macOS Cursor onboarding guard verified\n'
