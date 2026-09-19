#!/bin/bash
# statusLine wrapper — the only first-party feed of rate-limit data.
#
# Claude Code pipes a JSON payload here on every assistant message. We keep a copy
# for Raycast and hand the same stdin to whatever status line was configured before
# us, so installing the bridge never costs the user their own status line.
#
# Hot path: runs on every message. No `claude` subprocess, no network, no jq beyond
# one pass. Resolving which account this is belongs to the reader, not to us.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 0
# shellcheck source=lib.sh
. ./lib.sh 2>/dev/null || { cat >/dev/null; exit 0; }

payload=$(cat) || exit 0

emit_delegate() {
  local delegate
  delegate=$(cat "$INBOX_DIR/statusline-delegate" 2>/dev/null) || return 0
  [ -n "$delegate" ] || return 0
  printf '%s' "$payload" | eval "$delegate" 2>/dev/null
}

if inbox_ready && mkdir -p "$INBOX_DIR/usage" 2>/dev/null; then
  # Rate limits are per account, and an account is a config directory.
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  slug=$(printf '%s' "$cfg" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//')
  [ -n "$slug" ] && printf '%s' "$payload" | "$JQ" \
      --arg cfg "$cfg" --argjson ts "$(date +%s)" \
      '{ts: $ts, config_dir: $cfg,
        session_id: .session_id,
        model: (.model.display_name // null),
        rate_limits: (.rate_limits // null),
        context: (.context_window // null),
        cost: (.cost // null)}' 2>/dev/null \
    | inbox_write "$INBOX_DIR/usage/$slug.json"
fi

emit_delegate
exit 0
