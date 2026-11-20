import Foundation

/// What the agent knows about whether someone is at the Mac right now.
struct PresenceState {
    var asleep = false
    var displayAsleep = false
    var locked = false
    var wokeAt = Date.distantPast

    /// How long to wait after waking before alerting, so sound has time to come back.
    static let settleAfterWake: TimeInterval = 3

    /// True when someone is at the Mac and its sound has had a moment to come back after waking.
    func canAlert(at now: Date = Date()) -> Bool {
        !asleep && !displayAsleep && !locked && now.timeIntervalSince(wokeAt) >= Self.settleAfterWake
    }
}

/// Alerts that happen while the Mac is asleep, its screen is off or locked, or it has only just
/// woken are held until someone is back at it. A drive plugged in during sleep shows up the moment
/// the Mac wakes, often at the lock screen and before sound is working again, and its alert would
/// otherwise make no sound. Held alerts come out in the order they happened, and a new alert never
/// overtakes ones still waiting.
struct AlertHold<Item> {
    private(set) var waiting: [Item] = []

    var isHolding: Bool { !waiting.isEmpty }

    /// Adds an alert. Returns the alerts to deliver now, oldest first (empty while holding).
    mutating func add(_ item: Item, canAlert: Bool) -> [Item] {
        waiting.append(item)
        return release(canAlert: canAlert)
    }

    /// Returns everything waiting, oldest first, once alerting is possible again.
    mutating func release(canAlert: Bool) -> [Item] {
        guard canAlert, !waiting.isEmpty else { return [] }
        defer { waiting.removeAll() }
        return waiting
    }
}
