#!/bin/bash
# Fill the inbox with believable data so the UI can be judged before real
# sessions start reporting. Everything it writes carries "demo": true and is
# removed by --clear, so it can never be mistaken for a live request.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 1
# shellcheck source=lib.sh
. ./lib.sh

inbox_ready || { echo "cannot prepare $INBOX_DIR"; exit 1; }
mkdir -p "$INBOX_DIR/usage"

clear_demo() {
  local n=0
  for f in "$INBOX_DIR"/pending/*.json "$INBOX_DIR"/sessions/*.json "$INBOX_DIR"/usage/*.json; do
    [ -f "$f" ] || continue
    if [ "$("$JQ" -r '.demo // false' "$f" 2>/dev/null)" = "true" ]; then rm -f "$f"; n=$((n + 1)); fi
  done
  rm -f "$INBOX_DIR/.demo-watcher"
  echo "removed $n demo files"
}

[ "${1:-}" = "--clear" ] && { clear_demo; exit 0; }
clear_demo >/dev/null

now=$(date +%s)
pend() { # req, tool, input-json, cwd, ago
  "$JQ" -n --arg req "$1" --arg tool "$2" --argjson input "$3" --arg cwd "$4" --argjson ts "$((now - $5))" \
    '{demo:true, req:$req, kind:"permission", state:"blocked.permission", ts:$ts,
      session_id:("demo-" + $req), cwd:$cwd, tool_name:$tool, tool_input:$input,
      permission_mode:"default", transcript_path:null}' > "$INBOX_DIR/pending/$1.json"
}
sess() { # id, state, cwd, phase, ago, last message
  "$JQ" -n --arg id "$1" --arg st "$2" --arg cwd "$3" --arg ph "$4" --argjson ts "$((now - $5))" --arg msg "$6" \
    '{demo:true, session_id:$id, state:$st, ts:$ts, cwd:$cwd,
      phase:(if $ph == "" then null else $ph end), permission_mode:"default",
      transcript_path:null, last_message:(if $msg == "" then null else $msg end)}' > "$INBOX_DIR/sessions/$1.json"
}

pend demo01 Bash '{"command":"rm -rf dist && npm run build"}' "$HOME/work/skyaccess-api" 140
pend demo02 Write '{"file_path":"/Users/me/work/skyaccess-webapp/src/deploy.ts","content":"…"}' "$HOME/work/skyaccess-webapp" 420
pend demo03 Bash '{"command":"git push --force-with-lease origin staging"}' "$HOME/work/tarot" 60

sess demo-s1 working "$HOME/work/skyaccess-webapp" "pull" 240 ""
sess demo-s2 working "$HOME/work/morgan" "track" 720 ""
sess demo-s3 working "$HOME/work/english-blck" "scope" 900 ""
sess demo-s4 working "$HOME/work/livechat" "clean" 1500 ""
sess demo-s5 working "$HOME/work/redline" "pull" 1800 ""
sess demo-s6 working "$HOME/work/blckmeet" "qa" 2400 ""
sess demo-s7 idle "$HOME/work/finance-app" "" 300 "Waiting on you: which currency should the report default to?"
sess demo-s8 done "$HOME/work/telegram-voice" "" 90 "Shipped. Tests pass, PR opened."
sess demo-s9 failed "$HOME/work/bunker123" "" 600 "Build failed: missing DATABASE_URL."

"$JQ" -n --argjson ts "$((now - 180))" --arg cfg "$HOME/.claude" \
  --argjson five "$((now + 7300))" --argjson week "$((now + 250000))" \
  '{demo:true, ts:$ts, config_dir:$cfg, session_id:"demo-s1", model:"Opus 5",
    rate_limits:{five_hour:{used_percentage:38.4, resets_at:$five},
                 seven_day:{used_percentage:71.2, resets_at:$week}},
    context:{used_percentage:42.7, context_window_size:1000000},
    cost:{total_cost_usd:3.21}}' > "$INBOX_DIR/usage/demo.json"

# Stand in for the waiting hook: a verdict must make the row disappear, or the
# UI reads as broken during a demo.
if [ ! -f "$INBOX_DIR/.demo-watcher" ]; then
  touch "$INBOX_DIR/.demo-watcher"
  ( for _ in $(seq 1 12000); do
      [ -f "$INBOX_DIR/.demo-watcher" ] || break
      for v in "$INBOX_DIR"/verdicts/*.json; do
        [ -f "$v" ] || continue
        req=$(basename "$v" .json)
        p="$INBOX_DIR/pending/$req.json"
        if [ -f "$p" ] && [ "$("$JQ" -r '.demo // false' "$p" 2>/dev/null)" = "true" ]; then rm -f "$p" "$v"; fi
      done
      sleep 0.3
    done; rm -f "$INBOX_DIR/.demo-watcher" ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

echo "seeded: 3 waiting, 6 running, 1 idle, 1 done, 1 failed, usage 5h 38% / 7d 71%"
echo "clear with: $(pwd)/demo.sh --clear"
