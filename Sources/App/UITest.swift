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
        let pressed = Date()
        // Measures how long the app ever stops responding: a timer that should tick every 0.05 s.
        var lastTick = Date(), longestFreeze = 0.0
        let ticker = Timer(timeInterval: 0.05, repeats: true) { _ in
            longestFreeze = max(longestFreeze, Date().timeIntervalSince(lastTick))
            lastTick = Date()
        }
        RunLoop.main.add(ticker, forMode: .common)
        EjectSession.eject([volume]) { finished = true }

        // Waits for the window, then for its list, timing both from the moment Eject was pressed.
        waitUntil({ EjectSession.open.first?.shownWindow?.isVisible == true }) { opened in
            guard opened, let session = EjectSession.open.first, let window = session.shownWindow else {
                check(false, "the window opens for a drive that's in use")
                return done()
            }
            let openedAfter = Date().timeIntervalSince(pressed)
            check(openedAfter < 5, String(format: "the window opens for a drive that's in use, %.1f s after Eject", openedAfter))
            waitUntil({ !session.ejecting && !session.scanning }) { _ in
            check(!session.users.isEmpty, String(format: "its list of what's using the drive fills in %.1f s after Eject", Date().timeIntervalSince(pressed)))
            check(longestFreeze < 1, String(format: "the app never stops responding meanwhile (longest pause %.2f s; the spinning wheel starts at about 2 s)", longestFreeze))
            longestFreeze = 0
            after(0.3) {   // let the window finish fitting its filled-in list
            let needed = session.frameSize().height
            let actual = window.frame.height
            if let content = window.contentView {
                print(String(format: "      (window %.0f, content view %.0f, layout area %.0f, safe area top %.0f, min size %.0f, content min %.0f, fitting %.0f)",
                             window.frame.height, content.frame.height, window.contentLayoutRect.height, content.safeAreaInsets.top,
                             window.minSize.height, window.contentMinSize.height, content.fittingSize.height))
                // Ask for a few heights and read back what macOS actually applies.
                let original = window.frame
                for h in [300.0, needed, 600.0] {
                    var f = original; f.size.height = h
                    window.setFrame(f, display: false)
                    print(String(format: "      (asked for %.0f, got %.0f)", h, window.frame.height))
                }
                window.setFrame(original, display: false)
            }
            check(abs(actual - needed) < 4, String(format: "the window fits its content, no empty space (%.0f points tall, content needs %.0f)", actual, needed))
            check(actual < 700, String(format: "and isn't oversized (%.0f points tall)", actual))
            capture(window, as: "list")
            if let area = window.screen?.visibleFrame {
                let off = abs(window.frame.midX - area.midX)
                check(off < 2, "it's centered on the screen (off by \(Int(off)) points)")
                check(window.frame.maxY > area.minY + area.height * 0.75, "it sits high on the screen, like an alert")
            }
            check(NSApp.modalWindow == nil, "it doesn't block the rest of the app")

            guard click("Try Again", in: window) else { return done() }
            after(0.2) {
                check(session.checking, "right after clicking Try Again it shows Checking…")
                waitUntil({ !session.checking }) { _ in
                    after(0.3) { capture(window, as: "after-try-again") }
                    check(session.status != nil, "Try Again then says what it found: \(session.status ?? "nothing")")
                    check(longestFreeze < 1, String(format: "and the app kept responding while it checked (longest pause %.2f s)", longestFreeze))
                    check(window.isVisible, "the window stays open while the drive is still in use")

                    if !releasePIDs.isEmpty {
                        return tryAgainAfterReleasing(session, window) { finished }
                    }
                    // Let the window finish growing for the new status line, as a person would.
                    after(0.5) {
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
        print(String(format: "      (click %@: frame y %.0f–%.0f, content %.0f tall, flipped %@, point in window y %.0f, window %.0f tall; all: %@)",
                     title, frame.minY, frame.maxY, content.bounds.height, content.isFlipped ? "yes" : "no", inWindow.y,
                     window.frame.height,
                     session.buttonFrames.map { "\($0.key) \(Int($0.value.minY))" }.sorted().joined(separator: ", ")))
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

    /// Saves what the window shows to $UI_TEST_CAPTURE-<name>.png, so CI can keep a picture of the
    /// real window as it appeared on screen.
    private static func capture(_ window: NSWindow, as name: String) {
        guard let base = ProcessInfo.processInfo.environment["UI_TEST_CAPTURE"],
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(name).png"))
    }

    // MARK: Reporting

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    /// Checks every 0.1 s until the condition holds (true) or 15 s pass (false).
    private static func waitUntil(_ condition: @escaping () -> Bool, then next: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            if condition() { return next(true) }
            if Date() > deadline { return next(false) }
            after(0.1, poll)
        }
        poll()
    }

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func done() {
        exit(failures == 0 ? 0 : 1)
    }
}
