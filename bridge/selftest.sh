#!/bin/bash
# Round-trip the permission hook against a throwaway inbox: block, verdict, decide.
# Also proves the timeout path prints nothing, which is what keeps sessions safe.
set -uo pipefail
cd "$(dirname "$0")"

export CLAUDE_INBOX_DIR="${TMPDIR:-/tmp}/claude-inbox-selftest.$$"
trap 'rm -rf "$CLAUDE_INBOX_DIR"' EXIT

PAYLOAD='{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"/Users/me/work/skyaccess-api","tool_name":"Bash","tool_input":{"command":"rm -rf dist"},"permission_mode":"default","transcript_path":"/tmp/t.jsonl"}'
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$3] got [$2]"; fail=1; fi; }

echo "1. verdict arrives -> decision is returned"
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then
      req=$(basename "$f" .json)
      echo '{"decision":"allow","reason":"approved in test"}' > "$CLAUDE_INBOX_DIR/verdicts/$req.json"
      exit 0
    fi
    sleep 0.1
  done ) &
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=10 ./hook-permission.sh)
wait
check "decision" "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision')" "allow"
check "event"    "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.hookEventName')" "PermissionRequest"
check "reason"   "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.reason')" "approved in test"

echo "2. timeout -> no output, exit 0, pending cleaned up"
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=1 ./hook-permission.sh); rc=$?
check "exit code" "$rc" "0"
check "stdout"    "$out" ""
check "pending"   "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "3. garbage verdict -> ignored, no output"
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then echo 'not json at all' > "$CLAUDE_INBOX_DIR/verdicts/$(basename "$f" .json).json"; exit 0; fi
    sleep 0.1
  done ) &
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=5 ./hook-permission.sh)
wait
check "stdout" "$out" ""

echo "4. session registry"
printf '%s' '{"hook_event_name":"SessionStart","session_id":"s-2","cwd":"/Users/me/work/tarot","permission_mode":"default"}' | ./hook-session.sh
check "state" "$(/usr/bin/jq -r .state "$CLAUDE_INBOX_DIR/sessions/s-2.json" 2>/dev/null)" "working"
printf '%s' '{"hook_event_name":"Stop","session_id":"s-2","cwd":"/Users/me/work/tarot","last_assistant_message":"done here"}' | ./hook-session.sh
check "state after Stop" "$(/usr/bin/jq -r .state "$CLAUDE_INBOX_DIR/sessions/s-2.json" 2>/dev/null)" "idle"

echo
[ "$fail" = 0 ] && echo "all good" || { echo "FAILURES"; exit 1; }
