import AppKit
import Combine
import SwiftUI

/// What happens when a drive won't eject: a window listing what's using it, with
/// Quit Apps & Eject, Force Eject, Try Again and Cancel.
final class EjectSession: ObservableObject {
    enum Phase { case blocked, quitting, stillOpen }

    @Published private(set) var volumes: [MountedVolume]
    @Published private(set) var users: [DriveUser] = []
    @Published private(set) var phase: Phase = .blocked
    @Published private(set) var error: String?
    @Published private(set) var checking = false     // a retry is running: the button shows a spinner
    @Published private(set) var scanning = false     // finding what's using the drive
    @Published private(set) var ejecting = false     // the first eject attempt is still running
    @Published private(set) var forcing = false      // Force Eject is running
    @Published private(set) var status: String?      // what the last retry found
    @Published var showDifferences = false
    /// Where each button is drawn, in the window's content view from its top left. For the UI test.
    var buttonFrames: [String: CGRect] = [:]

    private var quitting: [NSRunningApplication] = []
    private var quitStarted = Date()
    private var timer: Timer?
    private var window: NSWindow?
    private let onFinish: () -> Void
    private let isSample: Bool

    /// Open sessions, kept alive while their window is up.
    private(set) static var open: [EjectSession] = []

    private init(volumes: [MountedVolume], onFinish: @escaping () -> Void) {
        self.volumes = volumes
        self.onFinish = onFinish
        isSample = false
    }

    /// Sample data for the README screenshots.
    init(sampleVolume: MountedVolume, users: [DriveUser], phase: Phase = .blocked, showDifferences: Bool = false) {
        volumes = [sampleVolume]
        self.users = users
        self.phase = phase
        self.showDifferences = showDifferences
        onFinish = {}
        isSample = true
    }

    /// Ejects the drives. Any that won't eject get the window.
    /// Ejects the drives without holding up the app (the work is in the background, so there's
    /// no spinning wheel). Any that won't eject get the window, which opens as soon as macOS says
    /// no and then fills in what's using them.
    static func eject(_ volumes: [MountedVolume], onFinish: @escaping () -> Void) {
        let session = EjectSession(volumes: volumes, onFinish: onFinish)
        Self.open.append(session)
        session.ejecting = true
        // A quick eject shows nothing (the agent's alert says it worked). If macOS takes longer
        // than half a second to answer, the window opens with "Ejecting…" so the wait shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if session.ejecting && session.window == nil { session.show() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.tryEjecting(volumes)
            DispatchQueue.main.async {
                session.ejecting = false
                session.volumes = result.stillThere
                if result.stillThere.isEmpty { return session.finish() }
                if session.window == nil { session.show() }
                session.scanInBackground(extra: result.dissenters)
            }
        }
    }

    // MARK: Actions

    func quitAppsAndEject() {
        quitting = users.filter(\.canQuit).compactMap { NSRunningApplication(processIdentifier: $0.id) }
        // A normal quit, the same as ⌘Q: apps save, or ask to.
        quitting.forEach { $0.terminate() }
        phase = .quitting
        quitStarted = Date()
        error = nil
        startTimer()
    }

    /// The question shown before Force Eject, while it's up. For the UI test.
    private(set) var confirmation: NSAlert?

    /// Asks before forcing, in a sheet on the window: Cancel is the default, so Return or Escape
    /// leaves everything as it was.
    func confirmForceEject() {
        guard !forcing, confirmation == nil else { return }
        guard let window else { return forceEject() }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = volumes.count == 1 ? "Force eject “\(volumes[0].name)”?" : "Force eject \(volumes.count) drives?"
        let it = volumes.count == 1 ? "it" : "them"
        let names = users.filter { $0.kind != .macOS }.map(\.name)
        let who: String
        switch names.count {
        case 0: who = "Anything still using \(it)"
        case 1: who = names[0]
        case 2: who = "\(names[0]) and \(names[1])"
        default: who = "\(names.count) apps"
        }
        a.informativeText = "\(who) will lose access to its files. Anything being saved to the drive right now can be lost or damaged."
        a.addButton(withTitle: "Cancel")
        let force = a.addButton(withTitle: "Force Eject")
        force.hasDestructiveAction = true
        confirmation = a
        a.beginSheetModal(for: window) { [weak self] response in
            self?.confirmation = nil
            if response == .alertSecondButtonReturn { self?.forceEject() }
        }
    }

    /// Unmounts in the background with the button showing "Ejecting…". The window closes as soon
    /// as the drive is unmounted, which is when it's safe to unplug; powering it down carries on
    /// without holding the window open.
    func forceEject() {
        guard !forcing else { return }
        stopTimer()
        error = nil
        forcing = true
        let pending = volumes
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [(MountedVolume, String)] = []
            for v in pending {
                if let why = ForceEject.run(mountPoint: v.url.path), VolumeInfo.isMounted(v.url.path) {
                    failed.append((v, why))
                }
            }
            DispatchQueue.main.async {
                self.forcing = false
                self.volumes = failed.map(\.0)
                if failed.isEmpty { return self.finish() }
                self.phase = .blocked
                self.error = "Couldn’t force eject " + failed.map { "“\($0.0.name)”: \($0.1)" }.joined(separator: "\n")
                self.scanInBackground(extra: [])
            }
        }
    }

    func tryAgain() {
        stopTimer()
        phase = .blocked
        error = nil
        retry()
    }

    func cancel() {
        stopTimer()
        finish()
    }

    // MARK: Ejecting

    /// Asks macOS to eject each drive, by device name (disk5): a path would count as looking inside
    /// the drive. Slow when a drive is busy, since macOS checks with everything involved before
    /// saying no, so this only ever runs in the background. Returns the drives still there, and
    /// anything macOS named as the reason (which can include processes the scan can't see).
    private static func tryEjecting(_ volumes: [MountedVolume]) -> (stillThere: [MountedVolume], dissenters: [DriveUser]) {
        var stillThere: [MountedVolume] = []
        var dissenters: [DriveUser] = []
        for v in volumes {
            guard let disk = VolumeInfo.wholeDisk(atMountPoint: v.url.path) else { continue }   // gone already
            let r = DriveUsers.run("/usr/sbin/diskutil", ["eject", disk])
            if r.status != 0 && VolumeInfo.isMounted(v.url.path) {
                stillThere.append(v)
                dissenters += DriveUsers.dissenters(inEjectError: r.output)
            }
        }
        return (stillThere, dissenters)
    }

    /// Finds what's using the drives in the background; the list shows "Checking…" meanwhile.
    private func scanInBackground(extra: [DriveUser]) {
        scanning = true
        let pending = volumes
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan(pending, extra: extra)
            DispatchQueue.main.async {
                self.scanning = false
                self.users = found
            }
        }
    }

    private static func scan(_ volumes: [MountedVolume], extra: [DriveUser]) -> [DriveUser] {
        var seen = Set<pid_t>()
        let found = volumes.flatMap { DriveUsers.scan(mountPoint: $0.url.path) } + extra
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Tries to eject again without freezing the window: the button shows "Checking…" meanwhile,
    /// for long enough to see. Still busy: the window shakes and says what it found, with the time,
    /// so every press visibly does something. Ejected: the window closes and the agent plays its sound.
    private func retry() {
        guard !checking else { return }
        checking = true
        let before = users
        let pending = volumes
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let (stillThere, dissenters) = Self.tryEjecting(pending)
            let found = Self.scan(stillThere, extra: dissenters)
            let wait = max(0, 0.7 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.checking = false
                self.volumes = stillThere
                if stillThere.isEmpty { self.finish(); return }
                self.users = found
                self.status = Self.status(before: before, after: found)
                self.shake()
            }
        }
    }

    /// "Still in use (checked at 3:42:10 PM)." or "Preview let go, but it’s still in use (…)."
    private static func status(before: [DriveUser], after: [DriveUser]) -> String {
        let time = Date().formatted(date: .omitted, time: .standard)
        let still = Set(after.map(\.id))
        let gone = before.filter { !still.contains($0.id) }.map(\.name)
        let checked = "(checked at \(time))."
        switch gone.count {
        case 0: return "Still in use " + checked
        case 1: return "\(gone[0]) let go, but it’s still in use " + checked
        case 2: return "\(gone[0]) and \(gone[1]) let go, but it’s still in use " + checked
        default: return "\(gone.count) apps let go, but it’s still in use " + checked
        }
    }

    /// The sideways shake macOS uses for "that didn't work". Left out with Reduce Motion on.
    private func shake() {
        guard let window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin = window.frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for offset in [-9.0, 9.0, -6.0, 6.0, -3.0, 3.0] {
            path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y))
        }
        path.addLine(to: origin)
        let animation = CAKeyframeAnimation()
        animation.path = path
        animation.duration = 0.4
        window.animations = ["frameOrigin": animation]
        window.animator().setFrameOrigin(origin)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkQuitting() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Once every app has quit, ejects. If some are still open after a few seconds, says which;
    /// they may be asking to save, so ejecting still happens by itself if they quit later.
    private func checkQuitting() {
        quitting.removeAll { $0.isTerminated }
        if quitting.isEmpty {
            stopTimer()
            phase = .blocked
            retry()
            return
        }
        if phase == .quitting && Date().timeIntervalSince(quitStarted) > 3 {
            phase = .stillOpen
            scanInBackground(extra: [])
        }
    }

    private func finish() {
        changes = nil
        window?.orderOut(nil)
        window = nil
        Self.open.removeAll { $0 === self }
        onFinish()
    }

    // MARK: Window

    /// Shown the way a macOS alert is: centered on the screen you're using, a little above the
    /// middle, in front of other windows. It doesn't block the rest of Disk Alert: a modal session
    /// ended from a timer or background step can outlive its window and leave every other
    /// button in the app dead. When it grows, its top stays put.
    private func show() {
        // The window sets its own size (fitToContent), once per change, to exactly what the SwiftUI
        // view wants, so the two never disagree. They did: through a hosting controller they
        // bounced until macOS stopped the app (the crash after Try Again), and with the content
        // extended under the title bar the view counted the title bar twice and kept growing the
        // window 32 points past it, which flickered black and see-through.
        let host = NSHostingView(rootView: PinnedToTop(session: self))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        // Dragged by its top edge only. Movable-by-background can take a click on a button for
        // the start of a drag, so the button never sees it.
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window = w

        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        w.setFrame(NSRect(origin: w.frame.origin, size: frameSize()), display: false)
        if UITest.isActive { print("      (show: frame \(w.frame.height), ejecting \(ejecting), scanning \(scanning), \(users.count) rows)") }
        if let area = screen?.visibleFrame {
            let frame = w.frame
            // Where macOS puts alerts: high on the screen. The top edge stays here and the window
            // grows downward as its list fills in, so it never jumps.
            let top = area.maxY - area.height * 0.18
            w.setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: max(area.minY, top - frame.height)))
        }
        anchorTop = w.frame.maxY
        // Whatever changes (the status line, the explanation, the list), fit the window afterwards.
        changes = objectWillChange.sink { [weak self] _ in self?.scheduleFit() }

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// For the UI test: the window, once shown.
    var shownWindow: NSWindow? { window }

    private var screen: NSScreen?
    private var anchorTop: CGFloat = 0
    private var changes: AnyCancellable?

    /// The window's frame size for its content at the fixed width. macOS adds the invisible title
    /// bar the content sits under, so only the content's own height goes in.
    func frameSize() -> NSSize {
        guard let window else { return .zero }
        // Measured from a fresh copy of the content every time. A copy kept for measuring isn't on
        // screen, so it can lag a change behind and give the previous layout's height.
        let fit = NSHostingView(rootView: EjectBlockedView(session: self)).fittingSize
        return window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 380, height: ceil(fit.height))).size
    }

    /// Several changes often arrive together (the list, the spinner, the status line); the window
    /// is measured once after all of them, not once per change, which kept the app busy.
    private var fitScheduled = false
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async {
            self.fitScheduled = false
            self.fitToContent()
        }
    }

    /// Resizes the window to its content, keeping the top edge where it was and the window on screen.
    private func fitToContent() {
        guard let window, let area = screen?.visibleFrame else { return }
        let size = frameSize()
        if UITest.isActive {
            print("      (fit: wants \(size.height), window \(window.frame.height), ejecting \(ejecting), scanning \(scanning), \(users.count) rows, status \(status != nil))")
        }
        guard abs(size.height - window.frame.height) >= 1 else { return }
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = window.frame.minX
        frame.origin.y = max(area.minY, min(anchorTop, area.maxY) - frame.height)
        window.setFrame(frame, display: true)
        if UITest.isActive { print("      (fit: now \(window.frame.height))") }
    }

    // MARK: Wording

    private var quittableNames: [String] {
        let listed = users.filter(\.canQuit).map(\.name)
        guard phase == .stillOpen else { return listed }
        let open = quitting.compactMap(\.localizedName)
        return open.isEmpty ? listed : open
    }

    var title: String {
        if phase == .stillOpen {
            let names = quittableNames
            switch names.count {
            case 1: return "\(names[0]) didn’t quit"
            case 2: return "\(names[0]) and \(names[1]) didn’t quit"
            default: return "\(names.count) apps didn’t quit"
            }
        }
        if ejecting {
            return volumes.count == 1 ? "Ejecting “\(volumes[0].name)”…" : "Ejecting \(volumes.count) drives…"
        }
        return volumes.count == 1 ? "Couldn’t eject “\(volumes[0].name)”" : "Couldn’t eject \(volumes.count) drives"
    }

    var summary: String {
        let it = volumes.count == 1 ? "it" : "them"
        switch phase {
        case .quitting:
            return "Quitting apps… Any with unsaved changes will ask to save first."
        case .stillOpen:
            let they = quittableNames.count == 1 ? "It" : "They"
            return "\(they) may be waiting for you to save, or not responding. Close \(they == "It" ? "it" : "them") yourself and Try Again, or Force Eject."
        case .blocked:
            if ejecting { return "Waiting for macOS to let go of \(it)…" }
            if scanning && users.isEmpty { return "Checking what’s using \(it)…" }
            let apps = users.filter { $0.kind == .app }.count
            let programs = users.filter { $0.kind == .process }.count
            let macOS = users.contains { $0.kind == .macOS }
            var parts: [String] = []
            if apps > 0 { parts.append(apps == 1 ? "1 app" : "\(apps) apps") }
            if programs > 0 { parts.append(programs == 1 ? "1 program" : "\(programs) programs") }
            if parts.isEmpty {
                return "macOS is still using \(it), perhaps indexing \(it) for Spotlight or backing up with Time Machine. Try again in a moment."
            }
            let verb = (apps + programs) == 1 ? "is" : "are"
            return parts.joined(separator: " and ") + " \(verb) using \(it)" + (macOS ? ", and macOS is using \(it) too." : ".")
        }
    }

    var offerQuit: Bool { phase == .blocked && users.contains(where: \.canQuit) }
}

// MARK: - The window's content

/// The content pinned to the top of the window, so nothing moves in the moment between the
/// content changing and the window resizing to fit it.
struct PinnedToTop: View {
    @ObservedObject var session: EjectSession
    var body: some View {
        EjectBlockedView(session: session)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EjectBlockedView: View {
    @ObservedObject var session: EjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 14, weight: .bold))
                Text(session.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            if session.ejecting {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 44)
            } else if session.scanning && session.users.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking what’s using it…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else if !session.users.isEmpty {
                list
            }

            if let status = session.status, !session.checking {
                Label(status, systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let error = session.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.ejecting {
            buttons

            Button(session.showDifferences ? "Hide the differences" : "What’s the difference?") {
                session.showDifferences.toggle()
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)

            if session.showDifferences { DifferencesView() }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 380)
    }

    /// Up to five rows show in full; more scroll inside the list, so the window never
    /// outgrows the screen and the buttons stay in view.
    @ViewBuilder private var list: some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(session.users.enumerated()), id: \.element.id) { index, user in
                if index > 0 { Divider() }
                DriveUserRow(user: user)
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if session.users.count > 5 {
                    ScrollView { rows }.frame(height: 270)
                } else {
                    rows
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))

            if session.users.count > 5 {
                Text("Scroll to see all \(session.users.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 8) {
            switch session.phase {
            case .blocked:
                if session.offerQuit {
                    wide("Quit Apps & Eject", prominent: true) { session.quitAppsAndEject() }
                        .keyboardShortcut(.defaultAction)
                }
                wide(session.forcing ? "Ejecting…" : "Force Eject", destructive: true, spinning: session.forcing) { session.confirmForceEject() }
                if session.offerQuit {
                    wide(tryTitle, spinning: session.checking) { session.tryAgain() }
                } else {
                    wide(tryTitle, prominent: true, spinning: session.checking) { session.tryAgain() }
                        .keyboardShortcut(.defaultAction)
                }
            case .quitting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for apps to quit…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                wide(session.forcing ? "Ejecting…" : "Force Eject", destructive: true, spinning: session.forcing) { session.confirmForceEject() }
            case .stillOpen:
                wide(tryTitle, prominent: true, spinning: session.checking) { session.tryAgain() }
                    .keyboardShortcut(.defaultAction)
                wide(session.forcing ? "Ejecting…" : "Force Eject", destructive: true, spinning: session.forcing) { session.confirmForceEject() }
            }
            wide("Cancel") { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 2)
        .disabled(session.checking || session.forcing)
    }

    private var tryTitle: String { session.checking ? "Checking…" : "Try Again" }

    /// Buttons keep their name for the UI test while they show a spinner.
    private static func frameKey(_ title: String) -> String {
        switch title {
        case "Checking…": return "Try Again"
        case "Ejecting…": return "Force Eject"
        default: return title
        }
    }

    private func wide(_ title: String, prominent: Bool = false, destructive: Bool = false, spinning: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Only Force Eject sets its own color. The default button's text is left to macOS,
            // which keeps it readable when this window isn't in front (the button turns grey then).
            HStack(spacing: 6) {
                if spinning { ProgressView().controlSize(.small) }
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(ProminenceStyle(prominent: prominent))
        // Where the button is, kept current for the UI test as the layout changes.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { [session] rect in
            session.buttonFrames[Self.frameKey(title)] = rect
        }
    }
}

/// Bordered, or the accent-colored default button.
private struct ProminenceStyle: PrimitiveButtonStyle {
    let prominent: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

struct DriveUserRow: View {
    let user: DriveUser

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.system(size: 12.5, weight: .semibold))
                Text(user.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if user.kind != .app {
                Text(user.kind == .macOS ? "Part of macOS, can’t be quit" : "Can’t be quit from here")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)   // wrap onto a second line, never cut off
                    .frame(width: 88, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var icon: some View {
        if let path = user.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: user.kind == .macOS ? "gearshape.fill" : "terminal.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}

/// The explanation behind "What's the difference?".
struct DifferencesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            item("Quit Apps & Eject", "Quits each app normally, the same as ⌘Q. Apps finish what they were writing and ask to save anything unsaved, so nothing is lost. Quitting an app closes all of its windows, not just the files on this drive.")
            item("Force Eject", "Ejects the drive now and leaves the apps running, but they lose access to its files. macOS still closes the drive properly, so it stays intact. Anything an app was in the middle of saving can be lost or damaged. If you were only viewing something, like a photo in Preview, it’s harmless, though the app may keep showing what it had already loaded.", red: true)
            item("Try Again", "Tries once more. Use it after closing things yourself, or after waiting for macOS to finish with the drive.")
            Divider()
            item("Pulling the cable instead", "Nothing gets the chance to finish, and the drive can be left marked as damaged.")
        }
        .font(.system(size: 11.5))
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ title: String, _ text: String, red: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.bold).foregroundStyle(red ? Color.red : Color.primary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
