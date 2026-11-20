#!/bin/bash
# Tests Disk Alert after ./scripts/build.sh. Needs macOS.
#  1. Unit tests for holding alerts while the Mac is asleep or locked (Tests/main.swift).
#  2. Runs the built agent against real disk images and checks what it records.
set -uo pipefail
cd "$(dirname "$0")/.."

AGENT="build/Disk Alert.app/Contents/Library/LoginItems/Disk Alert Agent.app/Contents/MacOS/DiskAlertAgent"
SUPPORT="$HOME/Library/Application Support/Disk Alert"
WORK="$(mktemp -d)"
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

echo "== Unit tests"
if xcrun swiftc Sources/Shared/AlertHold.swift Tests/main.swift -o "$WORK/unit-tests"; then
  "$WORK/unit-tests" || FAILED=1
else
  fail "unit tests compile"
fi

echo
echo "== What this Mac reports (alerts are held while it is asleep, locked or its display is off)"
cat > "$WORK/presence.swift" <<'EOF'
import CoreGraphics
let info = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
print("screen locked: \(info["CGSSessionScreenIsLocked"] ?? "not reported")")
print("on console: \(info["kCGSSessionOnConsoleKey"] ?? "not reported")")
print("main display asleep: \(CGDisplayIsAsleep(CGMainDisplayID()) != 0)")
EOF
xcrun swift "$WORK/presence.swift" || echo "(couldn't read presence)"

echo
echo "== Agent with real disk images"
# Prints "kind name" for each history entry, oldest first.
history() {
  python3 -c 'import json,sys
for e in reversed(json.load(open(sys.argv[1]))): print(e["kind"], e["name"])' "$SUPPORT/history.json" 2>/dev/null
}
wait_for() { # wait_for "<kind> <name>"
  for _ in $(seq 1 40); do history | grep -qx "$1" && return 0; sleep 0.5; done
  return 1
}

rm -rf "$SUPPORT"
hdiutil create -quiet -size 20m -fs HFS+ -volname "DA Before" "$WORK/before.dmg"
hdiutil create -quiet -size 20m -fs HFS+ -volname "DA Test" "$WORK/test.dmg"
hdiutil attach -quiet -nobrowse "$WORK/before.dmg"

"$AGENT" > "$WORK/agent.log" 2>&1 &
AGENT_PID=$!
sleep 6   # Drives already attached are noted silently for the agent's first 3 seconds.

hdiutil attach -quiet -nobrowse "$WORK/test.dmg"
if wait_for "connected DA Test"; then pass "attaching a disk image logs \"connected\""
else fail "attaching a disk image logs \"connected\" (held or missed)"; fi

hdiutil detach -quiet "/Volumes/DA Test"
if wait_for "ejected DA Test"; then pass "ejecting it logs \"ejected\""
else fail "ejecting it logs \"ejected\""; fi

if history | grep -q "DA Before"; then fail "a disk already attached at startup stays silent"
else pass "a disk already attached at startup stays silent"; fi

if python3 -c 'import json,sys; sys.exit(any(d["name"].startswith("DA ") for d in json.load(open(sys.argv[1])).values()))' \
     "$SUPPORT/drives.json" 2>/dev/null || [ ! -f "$SUPPORT/drives.json" ]; then
  pass "disk images stay out of the drive list"
else
  fail "disk images stay out of the drive list"
fi

if kill -0 "$AGENT_PID" 2>/dev/null; then pass "agent still running"; else fail "agent still running"; fi

echo
echo "History:"; history | sed 's/^/  /'
echo "Agent output:"; sed 's/^/  /' "$WORK/agent.log"

kill "$AGENT_PID" 2>/dev/null
hdiutil detach -quiet "/Volumes/DA Before" 2>/dev/null
hdiutil detach -quiet "/Volumes/DA Test" 2>/dev/null
rm -rf "$SUPPORT" "$WORK"

echo
[ "$FAILED" = 0 ] && echo "All tests passed." || echo "Some tests failed."
exit "$FAILED"
