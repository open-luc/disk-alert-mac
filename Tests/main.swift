import Foundation

// Tests for AlertHold and PresenceState. They use Foundation only, so they run on any Mac
// and on Linux:  swiftc Sources/Shared/AlertHold.swift Tests/main.swift -o tests && ./tests

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures += 1; print("      at line \(line)") }
}

let now = Date()
let longAgo = now.addingTimeInterval(-3600)

// MARK: PresenceState

check(PresenceState(wokeAt: longAgo).canAlert(at: now), "awake, unlocked, display on: alerts")
check(PresenceState().canAlert(at: now), "never slept since the agent started: alerts")
check(!PresenceState(asleep: true, wokeAt: longAgo).canAlert(at: now), "asleep: holds")
check(!PresenceState(displayAsleep: true, wokeAt: longAgo).canAlert(at: now), "display off: holds")
check(!PresenceState(locked: true, wokeAt: longAgo).canAlert(at: now), "screen locked: holds")
check(!PresenceState(wokeAt: now.addingTimeInterval(-1)).canAlert(at: now), "1 second after waking: holds")
check(!PresenceState(wokeAt: now.addingTimeInterval(-2.9)).canAlert(at: now), "2.9 seconds after waking: holds")
check(PresenceState(wokeAt: now.addingTimeInterval(-3)).canAlert(at: now), "3 seconds after waking: alerts")

// MARK: AlertHold

do {
    var hold = AlertHold<String>()
    check(hold.add("a", canAlert: true) == ["a"], "nothing waiting and free to alert: delivers at once")
    check(!hold.isHolding, "nothing left waiting afterwards")
}

do {
    var hold = AlertHold<String>()
    check(hold.add("connect", canAlert: false).isEmpty, "can't alert: holds the alert")
    check(hold.isHolding, "reports that it is holding")
    check(hold.release(canAlert: false).isEmpty, "still can't alert: keeps holding")
    check(hold.release(canAlert: true) == ["connect"], "free again: releases the held alert")
    check(!hold.isHolding && hold.release(canAlert: true).isEmpty, "releases it only once")
}

do {
    // Plugged in during sleep, then pulled out before waking: both alerts, in order.
    var hold = AlertHold<String>()
    _ = hold.add("connect", canAlert: false)
    _ = hold.add("unsafe", canAlert: false)
    _ = hold.add("connect again", canAlert: false)
    check(hold.release(canAlert: true) == ["connect", "unsafe", "connect again"], "releases held alerts in the order they happened")
}

do {
    // A new alert arriving just as alerting becomes possible must not overtake the held ones.
    var hold = AlertHold<String>()
    _ = hold.add("older", canAlert: false)
    check(hold.add("newer", canAlert: true) == ["older", "newer"], "a new alert never overtakes held ones")
}

// MARK: The scenario that was reported

do {
    // Drive plugged in while asleep; the Mac wakes to the lock screen; the user unlocks.
    var state = PresenceState(asleep: true, displayAsleep: true, wokeAt: longAgo)
    var hold = AlertHold<String>()
    let pluggedIn = now
    check(hold.add("SSD connected", canAlert: state.canAlert(at: pluggedIn)).isEmpty, "plugged in during sleep: held")

    let wake = now.addingTimeInterval(60)
    state.asleep = false; state.displayAsleep = false; state.locked = true; state.wokeAt = wake
    check(hold.release(canAlert: state.canAlert(at: wake.addingTimeInterval(0.5))).isEmpty, "woken to the lock screen: still held")

    state.locked = false
    let unlocked = wake.addingTimeInterval(1)
    check(hold.release(canAlert: state.canAlert(at: unlocked)).isEmpty, "unlocked within 3 seconds of waking: still held")
    check(hold.release(canAlert: state.canAlert(at: wake.addingTimeInterval(3))) == ["SSD connected"],
          "3 seconds after waking and unlocked: alert plays")
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
