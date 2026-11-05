#!/bin/zsh
# Prepares a README demo take for CleanShot X. Start its recording, activate Show & Tell with the real
# capture shortcut, click Copy & Open Claude, paste with ⌘V, verify the image, and submit it. The page reloads after Claude edits it.
#
#   scripts/record-demo.sh <name> --serve       serve the separate demo repo, open the page and lay out the windows (leave it running)
#   scripts/record-demo.sh <name> --save-take   save your latest capture's markers as the take to replay
#   scripts/record-demo.sh <name>               arm and guide a take (CleanShot records separately)
#
# Once: install Show & Tell Dev with scripts/dev.sh and run --serve; the page must come from it, not a file, to reload
# itself. Then mark the page up once by hand with Show & Tell Dev and run --save-take.
#
# DEMO_DIR defaults to ../snapback-demo (a separate Git repo with index.html); PORT defaults to 8766.
# Select this folder in Claude once, before recording. Submit only the attached image, without a text prompt.
# Every take puts Claude in the left half of LAYOUT and the page in the right, with space around and between the windows. Record the display below the menu bar in CleanShot.
# LAYOUT=x,y,w,h (points from the top left of the main display; default up to 1224×700, centred on screen);
# BROWSER defaults to Google Chrome. Show & Tell only switches to Claude, so have a new Claude Code session open
# in the demo folder before the take. Refuses uncommitted demo changes; restore the demo yourself before a repeat take.
set -euo pipefail
zmodload zsh/datetime
cd "$(dirname "$0")/.."

NAME=${1:?usage: scripts/record-demo.sh <name> [--serve | --save-take]}
DEMO=${DEMO_DIR:-$PWD/../snapback-demo}
TAKE=$PWD/demo/takes/$NAME.json
OUT=$PWD/build/demo
PAGE=$DEMO/index.html
TIMES=$OUT/$NAME.times
PORT=${PORT:-8766}
BROWSER=${BROWSER:-Google Chrome}
TITLE=$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$PAGE")
if [[ -z ${LAYOUT:-} ]]; then
  # Up to 1224×700, centred in the main display below the menu bar and above the Dock.
  LAYOUT=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); const screen = $.NSScreen.screens.objectAtIndex(0);
    const f = screen.frame, v = screen.visibleFrame, w = Math.min(1224, v.size.width - 56), h = Math.min(700, v.size.height - 80);
    const top = f.size.height - (v.origin.y + v.size.height);
    [Math.round(v.origin.x + (v.size.width - w) / 2), Math.round(top + (v.size.height - h) / 2), w, h].join(",")')
fi
mkdir -p "$OUT"

# Asks Show & Tell Dev to lay out the windows and, given a take, play it.
post() {
  rm -f "$TIMES"
  osascript -l JavaScript - "$LAYOUT" "$BROWSER" "$TITLE" "${1:-}" "$TIMES" <<'JS'
ObjC.import("Foundation")
function run([layout, browser, title, take, times]) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    "com.oralart.showandtell.dev.take", "record-demo", $({ layout, browser, title, take, times }), true)
}
JS
}

wait_for() {  # wait_for <seconds> <what> <condition…>
  local deadline=$(( EPOCHREALTIME + $1 )) what=$2; shift 2
  until "$@"; do
    if grep -q '^failed ' "$TIMES" 2>/dev/null; then
      echo "Show & Tell: $(sed -n 's/^failed \(.*\) [0-9.]*$/\1/p' "$TIMES")" >&2; exit 1
    fi
    (( EPOCHREALTIME < deadline )) || { echo "Timed out: $what" >&2; exit 1; }
    sleep 0.25
  done
}
logged() { grep -q "^$1 " "$TIMES" 2>/dev/null; }
NOT_RUNNING="Show & Tell Dev didn't answer; is it running? (scripts/dev.sh)"

cleanup() {
  [[ -n ${SERVER:-} ]] && kill $SERVER 2>/dev/null
  return 0
}
trap cleanup EXIT

serve() {
  if ! curl -s -o /dev/null "http://localhost:$PORT/"; then
    python3 -m http.server $PORT --bind 127.0.0.1 --directory "$DEMO" >/dev/null 2>&1 &
    SERVER=$!
    sleep 0.5
  fi
}

if [[ ${2:-} == --serve ]]; then
  serve
  URL=http://localhost:$PORT/
  # Keep Chrome's familiar tabs and address bar visible in the demo.
  if [[ $BROWSER == "Google Chrome" ]]; then
    open -na "Google Chrome" --args --new-window "$URL"
  else
    open -a "$BROWSER" "$URL"
  fi
  sleep 2
  post
  wait_for 3 "$NOT_RUNNING" logged arranged
  [[ -n ${SERVER:-} ]] || { echo "Windows laid out in $LAYOUT; the demo was already being served."; exit; }
  echo "Serving $DEMO at http://localhost:$PORT/ with the windows laid out in $LAYOUT. Ctrl-C to stop."
  wait $SERVER
fi

if [[ ${2:-} == --save-take ]]; then
  latest=$(ls -t "$HOME/Library/Application Support/Show & Tell/Captures"/*/capture.json | head -1)
  mkdir -p "${TAKE:h}"
  jq '{windowSize: .frame[1], markers}' "$latest" > "$TAKE"
  echo "Saved $(jq '.markers | length' "$TAKE") markers to $TAKE"
  exit
fi

[[ -f $TAKE ]] || { echo "No take yet: mark the page up by hand, then run with --save-take." >&2; exit 1; }
git -C "$DEMO" ls-files --error-unmatch index.html >/dev/null 2>&1 || { echo "Commit the demo baseline in $DEMO first." >&2; exit 1; }
serve

# Never silently overwrite an edit to the demo.
git -C "$DEMO" diff --quiet HEAD -- index.html || { echo "Restore or commit $PAGE before recording a new take." >&2; exit 1; }
original=$(stat -f %Fm "$PAGE")

# Arm the take before recording, so setup never appears in the video.
post "$TAKE"
wait_for 3 "$NOT_RUNNING" logged armed
echo "Start CleanShot recording with clicks and keystrokes enabled, then press Show & Tell’s capture shortcut (default ⇧⌘2)."
wait_for 130 "Show & Tell wasn't activated" logged start
wait_for 30 "the annotation didn't finish" logged annotated
echo "Click Copy & Open Claude in Show & Tell’s toolbar."
wait_for 90 "the take didn't finish" logged ready
echo "Paste the image into Claude with ⌘V, verify it, then submit it. Recording until the demo page changes…"

# Claude may edit more than once: wait for the first change, then until the file has been still for 5 seconds.
changed() { [[ $(stat -f %Fm "$PAGE") != $original ]]; }
wait_for 300 "Claude didn't change $PAGE" changed
last=$(stat -f %Fm "$PAGE")
still_since=$EPOCHREALTIME
while (( EPOCHREALTIME - still_since < 5 )); do
  sleep 0.25
  now=$(stat -f %Fm "$PAGE")
  if [[ $now != $last ]]; then last=$now; still_since=$EPOCHREALTIME; fi
done
echo "The demo file changed. Verify every requested fix in Chrome (reload if needed), hold on the final result, then stop CleanShot and save under build/demo/."
