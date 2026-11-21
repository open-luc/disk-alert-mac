import AppKit

/// Clicks the real eject window's buttons with mouse events, the way a person would, on a drive
/// that's in use. Run with: DiskAlert --ui-test-eject <mount point>
/// Prints PASS and FAIL lines, and exits with 0 when everything passed.
enum UITest {
    static let isActive = CommandLine.arguments.contains("--ui-test-eject")

    private static var failures = 0

    /// With --release <pid,pid>: after the first Try Again, those programs are stopped (as if you
    /// closed what was using the drive) and Try Again is pressed again, which should eject it.
    private static var releasePIDs: [pid_t] {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--release"), i + 1 < args.count else { return [] }
        return args[i + 1].split(separator: ",").compactMap { pid_t($0) }
    }

    private static var mountPoint: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-test-eject"), i + 1 < args.count else { return "" }
        return args[i + 1]
    }

    static func run() {
        NSApp.setActivationPolicy(.accessory)
        let path = mountPoint
        let volume = MountedVolume(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
                                   free: 0, total: 0, category: .drive)
        var finished = false
        EjectSession.eject([volume]) { finished = true }

        after(2) {
            guard let session = EjectSession.open.first, let window = session.shownWindow, window.isVisible else {
                check(false, "the window opens for a drive that's in use")
                return done()
            }
            check(true, "the window opens for a drive that's in use")
            if let area = window.screen?.visibleFrame {
                let off = abs(window.frame.midX - area.midX)
                check(off < 2, "it's centered on the screen (off by \(Int(off)) points)")
                check(window.frame.midY > area.midY, "it sits above the middle, like an alert")
            }
            check(NSApp.modalWindow == nil, "it doesn't block the rest of the app")

            guard click("Try Again", in: window) else { return done() }
            after(0.2) {
                check(session.checking, "right after clicking Try Again it shows Checking…")
                after(2.5) {
                    check(session.status != nil, "Try Again then says what it found: \(session.status ?? "nothing")")
                    check(window.isVisible, "the window stays open while the drive is still in use")

                    if !releasePIDs.isEmpty {
                        return tryAgainAfterReleasing(session, window) { finished }
                    }
                    guard click("Cancel", in: window) else { return done() }
                    after(1) {
                        check(!window.isVisible && finished, "Cancel closes the window")
                        check(NSApp.modalWindow == nil, "nothing is left blocking the app afterwards")
                        otherWindowStillWorks { done() }
                    }
                }
            }
        }
    }

    /// Stops what was using the drive, presses Try Again once more, and expects the drive to eject
    /// and the window to close, with the app still running.
    private static func tryAgainAfterReleasing(_ session: EjectSession, _ window: NSWindow, finished: @escaping () -> Bool) {
        releasePIDs.forEach { kill($0, SIGTERM) }
        after(1) {
            guard click("Try Again", in: window) else { return done() }
            after(0.2) {
                check(session.checking, "pressing Try Again again shows Checking… again")
                after(4) {
                    check(!VolumeInfo.isMounted(mountPoint), "once nothing is using it, Try Again ejects the drive")
                    check(!window.isVisible && finished(), "and the window closes by itself")
                    check(NSApp.modalWindow == nil, "nothing is left blocking the app afterwards")
                    otherWindowStillWorks { done() }
                }
            }
        }
    }

    /// A plain button in another window must still get clicks once the eject window is gone.
    private static func otherWindowStillWorks(then next: @escaping () -> Void) {
        final class Target: NSObject {
            var presses = 0
            @objc func press() { presses += 1 }
        }
        let target = Target()
        let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 220, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let button = NSButton(title: "Press", target: target, action: #selector(Target.press))
        button.frame = NSRect(x: 60, y: 30, width: 100, height: 32)
        w.contentView?.addSubview(button)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        after(0.5) {
            let r = button.convert(button.bounds, to: nil)
            post(click: w.convertPoint(toScreen: NSPoint(x: r.midX, y: r.midY)), in: w)
            after(0.8) {
                check(target.presses == 1, "a button in another Disk Alert window still works afterwards")
                w.orderOut(nil)
                next()
            }
        }
    }

    // MARK: Clicking

    /// Clicks the middle of the button with this title, where the window last drew it.
    /// (SwiftUI only builds its accessibility tree for a running screen reader, so the window
    /// records its button frames itself.)
    @discardableResult
    private static func click(_ title: String, in window: NSWindow) -> Bool {
        guard let session = EjectSession.open.first, let frame = session.buttonFrames[title],
              let content = window.contentView else {
            check(false, "finds the \(title) button (knows of: \(EjectSession.open.first?.buttonFrames.keys.sorted() ?? []))")
            return false
        }
        // The content view's coordinates start at the top left; the window's at the bottom left.
        let inContent = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
        let inWindow = content.convert(inContent, to: nil)
        post(click: window.convertPoint(toScreen: inWindow), in: window)
        return true
    }

    private static func post(click screenPoint: NSPoint, in window: NSWindow) {
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    // MARK: Reporting

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func done() {
        exit(failures == 0 ? 0 : 1)
    }
}
