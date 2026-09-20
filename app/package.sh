#!/bin/bash
# Put the app somewhere it can live, and optionally hand someone a disk image.
#
#   ./package.sh            build and install into /Applications
#   ./package.sh --dmg      also produce build/ClaudeInbox.dmg
#   ./package.sh --here     build only, leave it in build/ (what build.sh does)
#
# Why /Applications matters beyond tidiness: registering to open at login records
# the path the app was at. From a build directory that path is one `rm -rf .build`
# away from being wrong, and a login item pointing at nothing fails silently at
# the one moment it was supposed to work.
set -euo pipefail
cd "$(dirname "$0")"

NAME=ClaudeInbox
DEST=/Applications/$NAME.app
MODE=install
for arg in "$@"; do
  case "$arg" in
    --dmg) MODE=dmg ;;
    --here) MODE=here ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP=$(./build.sh release)
echo "built       $APP"
[ "$MODE" = here ] && exit 0

# A running copy cannot be replaced from under itself.
pkill -f "$NAME.app/Contents/MacOS/$NAME" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed   $DEST"

if [ "$MODE" = dmg ]; then
  STAGE=$(mktemp -d)
  cp -R "$DEST" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "build/$NAME.dmg"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -quiet -format UDZO "build/$NAME.dmg"
  rm -rf "$STAGE"
  echo "disk image  $(pwd)/build/$NAME.dmg"
  # Worth saying plainly rather than letting someone discover it: a disk image
  # needs no certificate, but an app inside one that was never notarised is
  # quarantined on another machine. The first open is right-click -> Open, or
  # `xattr -d com.apple.quarantine`. A Developer ID removes that step and nothing
  # else about this changes.
  echo "            unsigned: on another Mac the first open is right-click -> Open"
fi

open "$DEST"
echo "running     from /Applications"
