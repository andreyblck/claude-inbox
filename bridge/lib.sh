#!/bin/bash
# Shared helpers for the claude-inbox bridge hooks.
#
# Rule #1: never break a session. Every hook exits 0 and prints nothing the moment
# anything is off. A silent hook means "no decision", and Claude Code continues
# through its normal flow — so the bridge can only ever add a faster path, never
# take the existing one away.
#
# Rule #2, learned the hard way: printing the *wrong* thing is worse than printing
# nothing. An output that fails Claude Code's schema is surfaced into the session
# as an error, and from the outside it looks exactly like a hook that timed out.

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

# inbox_slug <path> — a filename-safe name for a config directory
inbox_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//'; }

# inbox_write <dest>  — atomic, so a reader never catches a half-written file
inbox_write() {
  local dest=$1 tmp="$1.$$.tmp"
  cat > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # An empty file is a row nothing can ever clear: jq failing mid-pipe still
  # leaves `cat` a clean exit, so the emptiness is the only signal we get.
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# inbox_wait <req_id> [timeout_s]  — echoes the verdict json, or returns 1 on timeout
inbox_wait() {
  local f="$INBOX_DIR/verdicts/$1.json"
  local timeout=${2:-300}
  case "$timeout" in *[!0-9]*|"") timeout=300 ;; esac
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$f" ]; then cat "$f" 2>/dev/null; rm -f "$f" 2>/dev/null; return 0; fi
    sleep 0.2
  done
  return 1
}

# inbox_listening [grace_s] — is anything on the other end?
#
# The app writes a heartbeat whenever it reads the inbox. Without this the hook
# blocks for its full timeout whenever the app is not running — a silent freeze
# before every permission prompt, in exchange for an answer that was never
# coming. The grace period covers an app that is starting up.
inbox_listening() {
  local grace=${1:-3} beat="$INBOX_DIR/heartbeat" deadline
  deadline=$(( $(date +%s) + grace ))
  while :; do
    if [ -f "$beat" ]; then
      local ts now
      ts=$(cat "$beat" 2>/dev/null) || ts=0
      case "$ts" in *[!0-9]*|"") ts=0 ;; esac
      now=$(date +%s)
      [ $(( now - ts )) -lt 60 ] && return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.3
  done
}

# inbox_reap — the inbox is append-only unless someone sweeps it.
#
# A hook killed with SIGKILL leaves its pending file behind, and nothing else ever
# removes one: the row sits in the UI for good, and approving it writes a verdict
# no process is waiting for. Every pending file carries the pid of the hook holding
# the request open, so a dead pid is a dead request.
inbox_reap() {
  local now f pid ts
  now=$(date +%s)
  for f in "$INBOX_DIR"/pending/*.json; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || { rm -f "$f" 2>/dev/null; continue; }
    pid=$("$JQ" -r '.pid // empty' "$f" 2>/dev/null)
    [ -n "$pid" ] || continue                       # demo rows and old formats stay
    kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null
  done
  # Answered in the terminal instead. The hook is still waiting and its pending
  # file is still a row, so the panel would show a question that is already
  # settled — for as long as the wait lasts.
  #
  # The tell has to be an event that means the *turn* moved on, not any touch of
  # the record. Claude Code fires a Notification about the very request being
  # waited on: taking that as "answered elsewhere" deleted every question card
  # the instant it appeared, which is worse than the staleness it was meant to
  # prevent. Only a prompt, the end of a turn, or the end of the session count.
  for f in "$INBOX_DIR"/pending/*.json; do
    [ -f "$f" ] || continue
    sid=$("$JQ" -r '.session_id // empty' "$f" 2>/dev/null) || continue
    [ -n "$sid" ] || continue
    rec="$INBOX_DIR/sessions/$sid.json"
    [ -f "$rec" ] || continue
    case "$("$JQ" -r '.event // empty' "$rec" 2>/dev/null)" in
      UserPromptSubmit|Stop|SessionEnd) ;;
      *) continue ;;
    esac
    pts=$("$JQ" -r '.ts // 0' "$f" 2>/dev/null)
    sts=$("$JQ" -r '.ts // 0' "$rec" 2>/dev/null) || continue
    case "$pts$sts" in *[!0-9]*) continue ;; esac
    [ "$sts" -gt "$pts" ] && rm -f "$f" 2>/dev/null
  done
  # A verdict written after its hook gave up has nobody to consume it.
  for f in "$INBOX_DIR"/verdicts/*.json; do
    [ -f "$f" ] || continue
    ts=$(/usr/bin/stat -f %m "$f" 2>/dev/null) || continue
    [ $(( now - ts )) -gt 3600 ] && rm -f "$f" 2>/dev/null
  done
  # One file per session, forever, all of them parsed on every poll.
  for f in "$INBOX_DIR"/sessions/*.json; do
    [ -f "$f" ] || continue
    ts=$("$JQ" -r '.ts // 0' "$f" 2>/dev/null) || continue
    case "$ts" in *[!0-9]*|"") continue ;; esac
    [ $(( now - ts )) -gt 172800 ] && rm -f "$f" 2>/dev/null
  done
  return 0
}
