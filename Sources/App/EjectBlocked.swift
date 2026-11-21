import AppKit
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
    @Published private(set) var status: String?      // what the last retry found
    @Published var showDifferences = false

    private var quitting: [NSRunningApplication] = []
    private var quitStarted = Date()
    private var timer: Timer?
    private var window: NSWindow?
    private let onFinish: () -> Void
    private let isSample: Bool

    /// Open sessions, kept alive while their window is up.
    private static var open: [EjectSession] = []

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
    static func eject(_ volumes: [MountedVolume], onFinish: @escaping () -> Void) {
        let session = EjectSession(volumes: volumes, onFinish: onFinish)
        session.attemptEject()
        if session.volumes.isEmpty { return }
        session.show()
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

    func forceEject() {
        stopTimer()
        error = nil
        var failed: [String] = []
        volumes = volumes.filter { v in
            if let why = ForceEject.run(mountPoint: v.url.path), VolumeInfo.isMounted(v.url.path) {
                failed.append("“\(v.name)”: \(why)")
                return true
            }
            return false
        }
        if volumes.isEmpty { finish(); return }
        phase = .blocked
        error = "Couldn’t force eject " + failed.joined(separator: "\n")
        rescan()
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

    private func attemptEject() {
        volumes = volumes.filter { v in
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url); return false }
            catch { return VolumeInfo.isMounted(v.url.path) }   // unplugged meanwhile: done
        }
        if volumes.isEmpty { finish(); return }
        rescan()
    }

    private func rescan() {
        users = Self.scan(volumes, extra: [])
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
            var stillThere: [MountedVolume] = []
            var dissenters: [DriveUser] = []
            for v in pending {
                let r = DriveUsers.run("/usr/sbin/diskutil", ["eject", v.url.path])
                if r.status != 0 && VolumeInfo.isMounted(v.url.path) {
                    stillThere.append(v)
                    dissenters += DriveUsers.dissenters(inEjectError: r.output)
                }
            }
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
            rescan()
        }
    }

    private func finish() {
        window?.orderOut(nil)
        window = nil
        Self.open.removeAll { $0 === self }
        onFinish()
    }

    // MARK: Window

    private func show() {
        let host = NSHostingController(rootView: EjectBlockedView(session: self))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        Self.open.append(self)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
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

            if !session.users.isEmpty { list }

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

            buttons

            Button(session.showDifferences ? "Hide the differences" : "What’s the difference?") {
                session.showDifferences.toggle()
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)

            if session.showDifferences { DifferencesView() }
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
                wide("Force Eject", destructive: true) { session.forceEject() }
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
                wide("Force Eject", destructive: true) { session.forceEject() }
            case .stillOpen:
                wide(tryTitle, prominent: true, spinning: session.checking) { session.tryAgain() }
                    .keyboardShortcut(.defaultAction)
                wide("Force Eject", destructive: true) { session.forceEject() }
            }
            wide("Cancel") { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 2)
        .disabled(session.checking)
    }

    private var tryTitle: String { session.checking ? "Checking…" : "Try Again" }

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
            item("Force Eject", "Ejects the drive now and leaves the apps running, but they lose access to its files. macOS still closes the drive properly, so it stays intact. Anything an app was in the middle of saving can be lost or damaged. If you were only viewing something, like a photo in Preview, it’s harmless.", red: true)
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
