#!/bin/bash
# Shared helpers for the claude-inbox bridge hooks.
#
# Rule #1: never break a session. Every hook exits 0 and prints nothing the moment
# anything is off. A silent hook means "no decision", and Claude Code continues
# through its normal flow — so the bridge can only ever add a faster path, never
# take the existing one away.

INBOX_DIR="${CLAUDE_INBOX_DIR:-$HOME/.claude/inbox}"
JQ=/usr/bin/jq

inbox_ready() {
  [ -x "$JQ" ] || return 1
  mkdir -p "$INBOX_DIR/sessions" "$INBOX_DIR/pending" "$INBOX_DIR/verdicts" 2>/dev/null || return 1
  # a verdict file approves a tool call, so nobody else on the box gets to write one
  chmod 700 "$INBOX_DIR" 2>/dev/null
  return 0
}

inbox_req_id() { /usr/bin/uuidgen | tr 'A-Z' 'a-z' | cut -c1-8; }

# inbox_write <dest>  — atomic, so a reader never catches a half-written file
inbox_write() {
  local dest=$1 tmp="$1.$$.tmp"
  cat > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$dest" 2>/dev/null
}

# inbox_wait <req_id> [timeout_s]  — echoes the verdict json, or returns 1 on timeout
inbox_wait() {
  local f="$INBOX_DIR/verdicts/$1.json"
  local deadline=$(( $(date +%s) + ${2:-300} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$f" ]; then cat "$f" 2>/dev/null; rm -f "$f" 2>/dev/null; return 0; fi
    sleep 0.2
  done
  return 1
}

# inbox_nudge — redraw the menu bar now instead of on its next 10s poll.
# The URL lives in a file because hooks inherit the session's environment, not ours.
inbox_nudge() {
  local url="${CLAUDE_INBOX_NUDGE_URL:-}"
  [ -n "$url" ] || url=$(cat "$INBOX_DIR/nudge-url" 2>/dev/null)
  [ -n "$url" ] || return 0
  /usr/bin/open -g "$url" >/dev/null 2>&1 || true
}
