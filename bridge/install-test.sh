#!/bin/bash
# install.sh edits the file that decides whether Claude Code runs at all, so every
# case below is one where getting it wrong costs the user something they cannot
# get back: their status line, their own hooks, or a working session.
#
# Everything runs against throwaway config and inbox directories. The real
# ~/.claude is never read for writing and never touched.
set -uo pipefail
cd "$(dirname "$0")"
BRIDGE=$(pwd)

# TMPDIR ends in a slash on macOS; normalise or every path comparison below
# fails on a doubled separator that means nothing.
ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/claude-inbox-install-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$3] got [$2]"; fail=1; fi; }
jqs() { /usr/bin/jq -r "$2" "$1" 2>/dev/null; }

fresh() { # fresh <name> -> echoes a config dir
  local d="$ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"
}

echo "1. a space in the path is a path, not two arguments"
# ~/Desktop/My Projects, an iCloud folder, a Google Drive mount. Unquoted, this
# broke every hook and the status line in the same install.
SPACED="$ROOT/My Projects/bridge"
mkdir -p "$SPACED"
cp lib.sh hook-permission.sh hook-session.sh statusline.sh install.sh "$SPACED/"
chmod +x "$SPACED"/*.sh
cfg=$(fresh cfg-space)
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-space" "$SPACED/install.sh" >/dev/null 2>&1
cmd=$(jqs "$cfg/settings.json" '.hooks.SessionStart[0].hooks[0].command')
check "command survives the space" "$(eval "printf '%s' $cmd" 2>/dev/null)" "$SPACED/hook-session.sh"
out=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"s-1","cwd":"/x"}' \
  | CLAUDE_INBOX_DIR="$ROOT/inbox-space" /bin/sh -c "$cmd" 2>&1)
check "and it actually runs"    "$?" "0"
check "writing where it should" "$([ -f "$ROOT/inbox-space/sessions/s-1.json" ] && echo yes || echo no)" "yes"

echo "2. installing twice leaves one copy"
cfg=$(fresh cfg-idem)
for _ in 1 2 3; do
  CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-idem" ./install.sh --wait 45 >/dev/null
done
check "PermissionRequest entries" "$(jqs "$cfg/settings.json" '[.hooks.PermissionRequest[].hooks[]] | length')" "1"
check "SessionStart entries"      "$(jqs "$cfg/settings.json" '[.hooks.SessionStart[].hooks[]] | length')" "1"
check "--wait reached the hook"   "$(jqs "$cfg/settings.json" '.hooks.PermissionRequest[0].hooks[0].command | test("TIMEOUT=45")')" "true"

echo "3. moving the repo does not leave a dead hook behind"
# Entries used to be recognised by the path they were installed from, so a rename
# or a second clone left the old ones failing on every single request forever.
MOVED="$ROOT/moved/bridge"
mkdir -p "$MOVED"
cp lib.sh hook-permission.sh hook-session.sh statusline.sh install.sh "$MOVED/"
chmod +x "$MOVED"/*.sh
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-idem" "$MOVED/install.sh" >/dev/null
check "still one permission hook" "$(jqs "$cfg/settings.json" '[.hooks.PermissionRequest[].hooks[]] | length')" "1"
check "pointing at the new path"  "$(jqs "$cfg/settings.json" '.hooks.PermissionRequest[0].hooks[0].command | test("moved/bridge")')" "true"
check "old path gone"             "$(jqs "$cfg/settings.json" '[.hooks[][].hooks[].command] | map(select(test("/bridge$"))) | length')" "0"

echo "4. other people's hooks are theirs"
cfg=$(fresh cfg-foreign)
/usr/bin/jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"/usr/local/bin/mine.sh"}]}],
                        SessionStart:[{hooks:[{type:"command",command:"/usr/local/bin/theirs.sh"}]}]},
                 statusLine:{type:"command",command:"my-statusline.sh"}}' > "$cfg/settings.json"
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-foreign" ./install.sh >/dev/null
check "foreign PreToolUse kept"   "$(jqs "$cfg/settings.json" '.hooks.PreToolUse[0].hooks[0].command')" "/usr/local/bin/mine.sh"
check "foreign SessionStart kept" "$(jqs "$cfg/settings.json" '[.hooks.SessionStart[].hooks[].command] | map(select(test("theirs"))) | length')" "1"

echo "5. the user's status line is wrapped, not taken"
check "delegate recorded"  "$(cat "$cfg/claude-inbox-statusline-delegate" 2>/dev/null)" "my-statusline.sh"
check "ours is installed"  "$(jqs "$cfg/settings.json" '.statusLine.command | test("statusline.sh")')" "true"
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-foreign" ./install.sh --uninstall >/dev/null
check "given back on uninstall" "$(jqs "$cfg/settings.json" '.statusLine.command')" "my-statusline.sh"
check "our hooks are gone"      "$(jqs "$cfg/settings.json" '[.hooks[][].hooks[].command] | map(select(test("hook-permission|hook-session"))) | length')" "0"
check "theirs are still there"  "$(jqs "$cfg/settings.json" '.hooks.PreToolUse[0].hooks[0].command')" "/usr/local/bin/mine.sh"

echo "6. the delegate lives with the settings it belongs to, so accounts do not trade status lines"
a=$(fresh cfg-a); b=$(fresh cfg-b)
/usr/bin/jq -n '{statusLine:{type:"command",command:"SL-A"}}' > "$a/settings.json"
/usr/bin/jq -n '{statusLine:{type:"command",command:"SL-B"}}' > "$b/settings.json"
CLAUDE_CONFIG_DIR="$a" CLAUDE_INBOX_DIR="$ROOT/inbox-ab" ./install.sh >/dev/null
CLAUDE_CONFIG_DIR="$b" CLAUDE_INBOX_DIR="$ROOT/inbox-ab" ./install.sh >/dev/null
check "A kept its own"    "$(cat "$a/claude-inbox-statusline-delegate")" "SL-A"
check "B kept its own"    "$(cat "$b/claude-inbox-statusline-delegate")" "SL-B"
CLAUDE_CONFIG_DIR="$a" CLAUDE_INBOX_DIR="$ROOT/inbox-ab" ./install.sh --uninstall >/dev/null
check "A restored to A"   "$(jqs "$a/settings.json" '.statusLine.command')" "SL-A"
check "B left installed"  "$(jqs "$b/settings.json" '.statusLine.command | test("statusline.sh")')" "true"

echo "7. both accounts are on record, so the reader can find their sessions"
check "two config dirs" "$(grep -c . "$ROOT/inbox-ab/config-dirs" 2>/dev/null)" "1"
check "and it is B"     "$(cat "$ROOT/inbox-ab/config-dirs")" "$b"

echo "8. --dry-run writes nothing"
# It used to create the inbox — the directory that holds verdict files, which
# approve tool calls — at the default 0755, from a command documented to write
# nothing at all.
cfg=$(fresh cfg-dry)
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-dry" ./install.sh --dry-run >/dev/null 2>&1
check "no settings written" "$([ -f "$cfg/settings.json" ] && echo yes || echo no)" "no"
check "no inbox created"    "$([ -d "$ROOT/inbox-dry" ] && echo yes || echo no)" "no"

echo "9. the inbox is not readable by anyone else"
check "mode 700" "$(/usr/bin/stat -f '%Lp' "$ROOT/inbox-idem")" "700"

echo "10. uninstall clears requests nothing is holding open any more"
cfg=$(fresh cfg-pending)
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-pending" ./install.sh >/dev/null
echo '{"req":"x"}' > "$ROOT/inbox-pending/pending/x.json"
CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-pending" ./install.sh --uninstall >/dev/null
check "stale request removed" "$(ls -1 "$ROOT/inbox-pending/pending" | wc -l | tr -d ' ')" "0"

echo "11. bad input is refused, not half-applied"
cfg=$(fresh cfg-bad)
CLAUDE_CONFIG_DIR="$cfg" ./install.sh --wait >/dev/null 2>&1
check "--wait with no value"  "$?" "2"
CLAUDE_CONFIG_DIR="$cfg" ./install.sh --wait abc >/dev/null 2>&1
check "--wait with nonsense"  "$?" "2"
check "nothing was written"   "$([ -f "$cfg/settings.json" ] && echo yes || echo no)" "no"
printf 'this is not json' > "$cfg/settings.json"
msg=$(CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-bad" ./install.sh 2>&1); rc=$?
check "broken settings refused"   "$rc" "1"
check "and left untouched"        "$(cat "$cfg/settings.json")" "this is not json"
check "with a message, not a trace" "$(printf '%s' "$msg" | grep -c 'not valid JSON')" "1"

echo "12. every backup is kept, even inside the same second"
cfg=$(fresh cfg-bak)
/usr/bin/jq -n '{statusLine:{type:"command",command:"ORIGINAL"}}' > "$cfg/settings.json"
for _ in 1 2 3; do CLAUDE_CONFIG_DIR="$cfg" CLAUDE_INBOX_DIR="$ROOT/inbox-bak" ./install.sh >/dev/null; done
check "three runs, three backups" "$(ls -1 "$cfg"/settings.json.bak-* 2>/dev/null | wc -l | tr -d ' ')" "3"
check "the first one is pristine" "$(/usr/bin/jq -r '.statusLine.command' "$(ls -1 "$cfg"/settings.json.bak-* | head -1)")" "ORIGINAL"

echo
[ "$fail" = 0 ] && echo "all good" || { echo "FAILURES"; exit 1; }
