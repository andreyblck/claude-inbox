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
BRIDGE=$(cd "$(dirname "$0")" && pwd) || exit 0
# shellcheck source=lib.sh
. "$BRIDGE/lib.sh" 2>/dev/null || { cat >/dev/null; exit 0; }

payload=$(cat) || exit 0

# An account is a config directory, and so is a status line: two accounts have two
# different ones. A single shared delegate file hands account A's status line to
# account B, and restores the wrong command when either is uninstalled.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

emit_delegate() {
  local delegate cwd
  delegate=$(cat "$CONFIG_DIR/claude-inbox-statusline-delegate" 2>/dev/null) \
    || delegate=$(cat "$INBOX_DIR/statusline-delegate" 2>/dev/null) \
    || return 0
  [ -n "$delegate" ] || return 0
  # Calling ourselves would be a fork bomb on every assistant message.
  case "$delegate" in *statusline.sh*) return 0 ;; esac

  # Status lines routinely run `git branch --show-current` or read $PWD. We are
  # started wherever Claude Code happened to be, so hand them the session's own
  # directory — otherwise every session on the machine reports this repo.
  cwd=$(printf '%s' "$payload" | "$JQ" -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    ( cd "$cwd" && printf '%s' "$payload" | eval "$delegate" ) 2>/dev/null
  else
    printf '%s' "$payload" | eval "$delegate" 2>/dev/null
  fi
}

if inbox_ready && mkdir -p "$INBOX_DIR/usage" 2>/dev/null; then
  # Rate limits are per account, and an account is a config directory.
  slug=$(inbox_slug "$CONFIG_DIR")
  [ -n "$slug" ] && printf '%s' "$payload" | "$JQ" \
      --arg cfg "$CONFIG_DIR" --argjson ts "$(date +%s)" \
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
