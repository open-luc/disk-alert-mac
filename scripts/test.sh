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
grep "^Notification:" "$WORK/agent.log" | sed 's/^/  /'
if grep -qE '^Notification: .* \| DA Test \| [0-9]{1,2}:[0-9]{2}' "$WORK/agent.log"; then pass "the connected alert starts with the time it happened"
else fail "the connected alert starts with the time it happened"; fi
if grep -qE '^Notification: .* \| DA Test \| [0-9]{1,2}:[0-9]{2}.* · Disk image closed$' "$WORK/agent.log"; then pass "the ejected alert says the time too"
else fail "the ejected alert says the time too"; fi

echo
echo "== A busy drive"
# The same code the app uses: NSWorkspace to eject, DriveUsers to list what's using the drive,
# ForceEject for Force Eject.
cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
let mode = CommandLine.arguments[1], path = CommandLine.arguments[2]
let started = Date()
// How long each step takes, to stderr so the results on stdout stay as they are.
defer { FileHandle.standardError.write(Data(String(format: "    (%@ took %.2f s)\n", mode, Date().timeIntervalSince(started)).utf8)) }
switch mode {
case "eject":
    do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path)); print("ejected") }
    catch { print(VolumeInfo.isMounted(path) ? "busy" : "gone") }
case "scan":
    for u in DriveUsers.scan(mountPoint: path) { print("\(u.kind)|\(u.name)|\(u.detail)") }
case "dissent":
    for u in DriveUsers.dissenters(inEjectError: path) { print("\(u.kind)|\(u.name)|\(u.detail)") }
case "eject-disk":
    // What the eject window does: diskutil, by device name.
    let r = DriveUsers.run("/usr/sbin/diskutil", ["eject", VolumeInfo.wholeDisk(atMountPoint: path) ?? path])
    print(r.status == 0 ? "ejected" : (VolumeInfo.isMounted(path) ? "busy" : "gone"))
case "force":
    let disk = VolumeInfo.wholeDisk(atMountPoint: path)
    let why = ForceEject.run(mountPoint: path)
    print(why == nil && !VolumeInfo.isMounted(path) ? "forced" : "failed: \(why ?? "still mounted")")
    FileHandle.standardError.write(Data(String(format: "    (unmounted after %.2f s; the window closes here)\n", Date().timeIntervalSince(started)).utf8))
    // The app lets the drive finish ejecting in the background. This helper waits for that, so the
    // disk image is fully detached before the next test attaches it again.
    if let disk {
        for _ in 0..<100 where FileManager.default.fileExists(atPath: "/dev/" + disk) { Thread.sleep(forTimeInterval: 0.1) }
    }
default:
    print("unknown mode")
}
SWIFT
BUSY="/Volumes/DA Busy"
hdiutil create -quiet -size 20m -fs HFS+ -volname "DA Busy" "$WORK/busy.dmg"
if xcrun swiftc -O Sources/Shared/*.swift "$WORK/main.swift" -o "$WORK/drive"; then
  hdiutil attach -quiet -nobrowse "$WORK/busy.dmg"
  # Another program works in a folder on the drive. Started first, so it can't inherit the file below.
  (cd "$BUSY" && exec sleep 120) & SLEEP_PID=$!
  exec 3>"$BUSY/open file.txt"                  # this script keeps a file open on the drive
  # A program that loads a photo straight into memory and closes the file, as Preview does.
  head -c 65536 /dev/urandom > "$BUSY/IMG_4021.HEIC"
  python3 -c 'import mmap,sys,time; f=open(sys.argv[1],"rb"); m=mmap.mmap(f.fileno(),0,prot=mmap.PROT_READ); f.close(); time.sleep(120)' "$BUSY/IMG_4021.HEIC" 3>&- & MAP_PID=$!
  sleep 1

  r=$("$WORK/drive" eject-disk "$BUSY"); echo "  eject while in use: $r"
  if [ "$r" = busy ]; then pass "a drive in use fails to eject and is still there"
  else fail "a drive in use fails to eject and is still there"; fi

  echo "  lsof reports:"; /usr/sbin/lsof -n -P -- "$BUSY" 2>&1 | sed 's/^/    /'
  scan=$("$WORK/drive" scan "$BUSY"); echo "$scan" | sed 's/^/  using it: /'
  if echo "$scan" | grep -q '|“open file.txt” is open$'; then pass "lists the program with a file open, and which file"
  else fail "lists the program with a file open, and which file"; fi
  if echo "$scan" | grep -q '^process|sleep|Working in a folder on this drive$'; then pass "lists a program working in a folder on the drive"
  else fail "lists a program working in a folder on the drive"; fi
  if echo "$scan" | grep -qi '^process|python[^|]*|“IMG_4021.HEIC” is open$'; then pass "a photo loaded into memory shows as that file, not \"running from this drive\""
  else fail "a photo loaded into memory shows as that file, not \"running from this drive\""; fi

  echo "  diskutil's reason (Try Again reads it for processes the scan can't see):"
  /usr/sbin/diskutil eject "$BUSY" 2>&1 | sed 's/^/    /'
  r=$("$WORK/drive" dissent "Volume DA Busy on disk9s1 failed to unmount: dissented by PID $$ (/bin/bash)")
  echo "  parsed: $r"
  if [ "$r" = "process|bash|Using this drive" ]; then pass "reads which process blocked the eject from macOS's error"
  else fail "reads which process blocked the eject from macOS's error"; fi

  echo "  Clicking the real eject window's buttons:"
  APP="build/Disk Alert.app/Contents/MacOS/DiskAlert"
  ui=$(UI_TEST_CAPTURE="$PWD/build/eject-window-real" perl -e 'alarm 60; exec @ARGV' "$APP" --ui-test-eject "$BUSY" 2>&1); ui_status=$?
  echo "$ui" | sed 's/^/    /'
  if [ "$ui_status" = 0 ] && ! echo "$ui" | grep -q '^FAIL'; then pass "the eject window's buttons respond to real clicks"
  else fail "the eject window's buttons respond to real clicks (exit $ui_status)"; fi

  r=$("$WORK/drive" force "$BUSY"); echo "  force eject: $r"
  if [ "$r" = forced ] && [ ! -d "$BUSY" ]; then pass "Force Eject ejects a drive that's still in use"
  else fail "Force Eject ejects a drive that's still in use"; fi
  sleep 1
  if grep -q "Force eject: disk" "$WORK/agent.log"; then pass "the agent counts a Force Eject as an eject, not an unplug"
  else fail "the agent counts a Force Eject as an eject, not an unplug"; fi
  exec 3>&-; kill "$SLEEP_PID" "$MAP_PID" 2>/dev/null

  # Try Again: close what was using it, then eject works.
  hdiutil attach -quiet -nobrowse "$WORK/busy.dmg"
  exec 3>"$BUSY/open file.txt"
  r=$("$WORK/drive" eject "$BUSY"); echo "  eject with a file open: $r"
  exec 3>&-
  r2=$("$WORK/drive" eject "$BUSY"); echo "  after closing it: $r2"
  if [ "$r" = busy ] && [ "$r2" = ejected ]; then pass "Try Again after closing the file ejects it"
  else fail "Try Again after closing the file ejects it"; fi

  # The same in the real window, by clicking: Try Again while busy, then close what was using
  # the drive and Try Again once more. It must eject, close the window, and not crash.
  echo "  Clicking Try Again until it works:"
  hdiutil attach -quiet -nobrowse "$WORK/busy.dmg"
  (cd "$BUSY" && exec sleep 120) & H1=$!
  python3 -c 'import mmap,sys,time; f=open(sys.argv[1],"rb"); m=mmap.mmap(f.fileno(),0,prot=mmap.PROT_READ); f.close(); time.sleep(120)' "$BUSY/IMG_4021.HEIC" & H2=$!
  sleep 1
  ui=$(perl -e 'alarm 60; exec @ARGV' "$APP" --ui-test-eject "$BUSY" --release "$H1,$H2" 2>&1); ui_status=$?
  echo "$ui" | sed 's/^/    /'
  if [ "$ui_status" = 0 ] && ! echo "$ui" | grep -q '^FAIL'; then pass "Try Again ejects once the drive is free, without crashing"
  else fail "Try Again ejects once the drive is free, without crashing (exit $ui_status)"; fi
else
  fail "drive helper compiles"
fi

echo
echo "== Release notes scroll with a mouse wheel"
out=$(perl -e 'alarm 30; exec @ARGV' "build/Disk Alert.app/Contents/MacOS/DiskAlert" --ui-test-scroll 2>&1); status=$?
echo "$out" | sed 's/^/  /'
if [ "$status" = 0 ] && ! echo "$out" | grep -q '^FAIL'; then pass "mouse-wheel scrolling in the release notes is immediate"
else fail "mouse-wheel scrolling in the release notes is immediate (exit $status)"; fi

echo
echo "== Updating, end to end"
# A copy of the app, labelled as an old version, installs this build's real installer over itself
# the way Check for Updates does after downloading: prepares the new version while still running,
# quits, gets swapped and relaunched, and the new version finishes the progress bar with "Updated".
DMG="$(ls build/*.dmg 2>/dev/null | head -1)"
APPS="$WORK/Apps"; COPY="$APPS/Disk Alert.app"; mkdir -p "$APPS"
REAL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build/Disk Alert.app/Contents/Info.plist")
ditto "build/Disk Alert.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" -c "Set :DAPrerelease ''" "$COPY/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$COPY" 2>/dev/null
defaults delete app.diskalert updatedFrom 2>/dev/null; defaults delete app.diskalert lastUpdateShown 2>/dev/null
if [ -n "$DMG" ]; then
  out=$(perl -e 'alarm 60; exec @ARGV' "$COPY/Contents/MacOS/DiskAlert" --ui-test-update "$PWD/$DMG" 2>&1); status=$?
  quit=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  echo "$out" | sed 's/^/  /'
  [ "$status" = 0 ] && pass "the old version prepares the update and quits" || fail "the old version prepares the update and quits (exit $status)"
  # Wait for the new version to open and show "Updated".
  for _ in $(seq 1 100); do defaults read app.diskalert lastUpdateShown >/dev/null 2>&1 && break; sleep 0.2; done
  back=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  shown=$(defaults read app.diskalert lastUpdateShown 2>/dev/null)
  installed=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$COPY/Contents/Info.plist" 2>/dev/null)
  echo "  installed version: $installed (expected $REAL_VERSION); the new version said: Updated to $shown"
  echo "  from the old version quitting to the new one showing Updated: $(perl -e "printf '%.1f', $back - $quit") s"
  [ "$installed" = "$REAL_VERSION" ] && pass "the new version replaced the old one" || fail "the new version replaced the old one"
  [ -n "$shown" ] && pass "the new version opened and showed Updated" || fail "the new version opened and showed Updated"
  if [ ! -e "$APPS/.Disk Alert update.app" ] && [ ! -e "$COPY.old" ]; then pass "nothing is left behind"
  else fail "nothing is left behind"; ls -la "$APPS"; fi
  codesign --verify --deep --strict "$COPY" 2>/dev/null && pass "the installed app is intact (signature checks out)" || fail "the installed app is intact (signature checks out)"
  ! defaults read app.diskalert updatedFrom >/dev/null 2>&1 && pass "the update note was cleared" || fail "the update note was cleared"
else
  fail "found this build's installer"
fi
pkill -f "$COPY/Contents/MacOS/DiskAlert" 2>/dev/null
launchctl bootout "gui/$(id -u)/app.diskalert.agent" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/app.diskalert.agent.plist"

echo
# If Disk Alert crashed during any of this, show macOS's crash report.
for report in $(ls -t "$HOME/Library/Logs/DiagnosticReports"/DiskAlert* 2>/dev/null | head -2); do
  fail "Disk Alert crashed: $report"
  head -c 6000 "$report" | sed 's/^/    /'
done

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
