#!/bin/bash
# Tests Disk Alert after ./scripts/build.sh. Needs macOS.
#  1. Unit tests (Tests/main.swift): holding alerts while the Mac is asleep or locked, release notes.
#  2. Runs the built agent against real disk images and checks what it records.
#  3. A busy drive: what's using it, Try Again, and Force Eject (which the agent must count as an eject).
set -uo pipefail
cd "$(dirname "$0")/.."

AGENT="build/Disk Alert.app/Contents/Library/LoginItems/Disk Alert Agent.app/Contents/MacOS/DiskAlertAgent"
SUPPORT="$HOME/Library/Application Support/Disk Alert"
WORK="$(mktemp -d)"
FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

echo "== Unit tests"
if xcrun swiftc Sources/Shared/AlertHold.swift Sources/Shared/ReleaseNotes.swift Tests/main.swift -o "$WORK/unit-tests"; then
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
echo "== A busy drive"
# The same code the app uses: NSWorkspace to eject, DriveUsers to list what's using the drive,
# ForceEject for Force Eject.
cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
let mode = CommandLine.arguments[1], path = CommandLine.arguments[2]
switch mode {
case "eject":
    do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path)); print("ejected") }
    catch { print(VolumeInfo.isMounted(path) ? "busy" : "gone") }
case "scan":
    for u in DriveUsers.scan(mountPoint: path) { print("\(u.kind)|\(u.name)|\(u.detail)") }
case "force":
    let why = ForceEject.run(mountPoint: path)
    print(why == nil && !VolumeInfo.isMounted(path) ? "forced" : "failed: \(why ?? "still mounted")")
default:
    print("unknown mode")
}
SWIFT
BUSY="/Volumes/DA Busy"
hdiutil create -quiet -size 20m -fs HFS+ -volname "DA Busy" "$WORK/busy.dmg"
if xcrun swiftc -O Sources/Shared/*.swift "$WORK/main.swift" -o "$WORK/drive"; then
  hdiutil attach -quiet -nobrowse "$WORK/busy.dmg"
  exec 3>"$BUSY/open file.txt"                  # this script keeps a file open on the drive
  (cd "$BUSY" && exec sleep 120) & SLEEP_PID=$!   # and another program works in a folder on it
  sleep 1

  r=$("$WORK/drive" eject "$BUSY"); echo "  eject while in use: $r"
  if [ "$r" = busy ]; then pass "a drive in use fails to eject and is still there"
  else fail "a drive in use fails to eject and is still there"; fi

  scan=$("$WORK/drive" scan "$BUSY"); echo "$scan" | sed 's/^/  using it: /'
  if echo "$scan" | grep -q '|“open file.txt” is open$'; then pass "lists the program with a file open, and which file"
  else fail "lists the program with a file open, and which file"; fi
  if echo "$scan" | grep -q '^process|sleep|Working in a folder on this drive$'; then pass "lists a program working in a folder on the drive"
  else fail "lists a program working in a folder on the drive"; fi

  r=$("$WORK/drive" force "$BUSY"); echo "  force eject: $r"
  if [ "$r" = forced ] && [ ! -d "$BUSY" ]; then pass "Force Eject ejects a drive that's still in use"
  else fail "Force Eject ejects a drive that's still in use"; fi
  sleep 1
  if grep -q "Force eject: disk" "$WORK/agent.log"; then pass "the agent counts a Force Eject as an eject, not an unplug"
  else fail "the agent counts a Force Eject as an eject, not an unplug"; fi
  exec 3>&-; kill "$SLEEP_PID" 2>/dev/null

  # Try Again: close what was using it, then eject works.
  hdiutil attach -quiet -nobrowse "$WORK/busy.dmg"
  exec 3>"$BUSY/open file.txt"
  r=$("$WORK/drive" eject "$BUSY"); echo "  eject with a file open: $r"
  exec 3>&-
  r2=$("$WORK/drive" eject "$BUSY"); echo "  after closing it: $r2"
  if [ "$r" = busy ] && [ "$r2" = ejected ]; then pass "Try Again after closing the file ejects it"
  else fail "Try Again after closing the file ejects it"; fi
else
  fail "drive helper compiles"
fi

echo
echo "History:"; history | sed 's/^/  /'
echo "Agent output:"; sed 's/^/  /' "$WORK/agent.log"

kill "$AGENT_PID" 2>/dev/null
hdiutil detach -quiet "/Volumes/DA Before" 2>/dev/null
hdiutil detach -quiet "/Volumes/DA Test" 2>/dev/null
hdiutil detach -quiet -force "$BUSY" 2>/dev/null
rm -rf "$SUPPORT" "$WORK"

echo
[ "$FAILED" = 0 ] && echo "All tests passed." || echo "Some tests failed."
exit "$FAILED"
