import AppKit
import Foundation
import SwiftUI

/// Checks GitHub Releases for a newer Disk Alert and installs it.
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    static let repo = "open-luc/disk-alert-mac"

    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, updated, failed(String)
    }

    @Published var state: State = .idle
    @Published var progress: Double? = nil          // 0...1 while downloading, nil when unknown
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    /// One bar for the whole update: downloading fills most of it, preparing the new version the
    /// rest, and the new version shows it full when it opens.
    @Published var overall: Double = 0
    @Published var step = ""
    @Published var updatedFrom = ""
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var progressWindow: NSWindow?
    var pendingVersion = ""   // the version being installed, as people read it
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    @Published var automatic: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdateCheck") }
    }

    /// Opt-in from Settings › General › Alpha Builds. Alphas are only ever offered when you
    /// check by hand, and only once you're up to date with the public release.
    @Published var alphaOptIn: Bool = UserDefaults.standard.bool(forKey: "alphaUpdates") {
        didSet { UserDefaults.standard.set(alphaOptIn, forKey: "alphaUpdates") }
    }

    private var timer: Timer?

    /// The full version, e.g. "0.4.1" or "0.4.1-alpha.18".
    var currentVersion: String {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let pre = Bundle.main.object(forInfoDictionaryKey: "DAPrerelease") as? String ?? ""
        return pre.isEmpty ? base : "\(base)-\(pre)"
    }

    var isAlpha: Bool { Version(currentVersion).pre != nil }

    /// A fingerprint of the source code this copy was built from (see scripts/build.sh).
    var sourceHash: String { Bundle.main.object(forInfoDictionaryKey: "DASourceHash") as? String ?? "" }

    /// Whether a release is this very app under another number, such as the public release
    /// made from the same code as the alpha you have.
    func isSameApp(as release: Release) -> Bool {
        !sourceHash.isEmpty && ReleaseNotes.sourceHash(in: release.body ?? "") == sourceHash
    }

    /// The version as people read it, e.g. "0.4.1" or "0.4.1 Alpha 18".
    var displayVersion: String { Self.display(currentVersion) }

    static func display(_ version: String) -> String {
        let v = Version(version)
        let base = v.nums.map(String.init).joined(separator: ".")
        guard let pre = v.pre else { return base }
        return "\(base) Alpha \(pre)"
    }

    /// Checks once a day while the app runs, if automatic checks are on.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkIfDue() }
    }

    private func checkIfDue() {
        guard automatic else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]
        let prerelease: Bool?
        let draft: Bool?
        var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    func check(userInitiated: Bool) {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        // The whole list, not "latest", which never includes alphas.
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                self.lastChecked = Date()
                UserDefaults.standard.set(self.lastChecked, forKey: "lastUpdateCheck")
                guard let data, error == nil,
                      let releases = try? JSONDecoder().decode([Release].self, from: data) else {
                    self.state = .failed("Couldn’t reach GitHub.")
                    if userInitiated { self.alert("Couldn’t check for updates", "Check your internet connection and try again.") }
                    return
                }
                self.handle(releases, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(_ releases: [Release], userInitiated: Bool) {
        let published = releases.filter { $0.draft != true }
        let newest = { (list: [Release]) in list.max { Version($0.version) < Version($1.version) } }
        let stable = newest(published.filter { $0.prerelease != true })
        let alpha = newest(published.filter { $0.prerelease == true })

        // A newer public release always comes first, unless it's the same app you already have.
        if let stable, Self.isNewer(stable.version, than: currentVersion), !isSameApp(as: stable) {
            state = .available(stable.version)
            offer(stable, version: stable.version)
            return
        }
        state = .upToDate
        guard userInitiated else { return }

        // Alphas are offered only when asked, and never pushed: Not Now is the default.
        if alphaOptIn, let alpha, Self.isNewer(alpha.version, than: currentVersion) {
            offerAlpha(alpha, stable: stable)
            return
        }
        let upToDate = upToDateText(stable: stable, alpha: alpha)
        // On an alpha, the public release can be installed instead, from the same message.
        if isAlpha, let stable, !isSameApp(as: stable) {
            NSApp.activate(ignoringOtherApps: true)
            let a = Self.makeAlert("You’re up to date", upToDate.text, footnote: upToDate.footnote)
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Switch to Public Release…")
            if a.runModal() == .alertSecondButtonReturn { switchToPublic(stable) }
            return
        }
        alert("You’re up to date", upToDate.text, footnote: upToDate.footnote)
    }

    /// Leaves the alpha for the public release. That usually means going back to an older version,
    /// so it asks first, and it turns alpha builds off so Check for Updates doesn't offer the alpha
    /// straight back.
    private func switchToPublic(_ stable: Release) {
        let name = Self.display(stable.version)
        let older = Version(stable.version) < Version(currentVersion)
        let a = NSAlert()
        a.messageText = "Switch to Disk Alert \(name)?"
        a.informativeText = (older
            ? "\(name) is older than the alpha you have (\(displayVersion)), so anything the alpha added that isn’t in a public release yet goes away. "
            : "")
            + "Your settings, drives and sounds stay as they are. Alpha builds turn off, so Check for Updates only offers public releases from now on. You can turn them back on in Settings."
        a.addButton(withTitle: "Switch to \(name)")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let dmg = stable.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: dmg.browser_download_url) else {
            alert("Couldn’t switch", "This release has no .dmg installer attached.")
            return
        }
        alphaOptIn = false
        pendingVersion = name
        install(from: url)
    }

    /// One line: the version you have, and in brackets why it's current. On an alpha, a smaller
    /// line underneath gives the public release for comparison.
    /// "You have 0.4.1 (the latest version)." or "You have 0.5.0 Alpha 35 (the latest alpha)."
    private func upToDateText(stable: Release?, alpha: Release?) -> (text: String, footnote: String?) {
        let you = "You have \(displayVersion)"
        guard isAlpha else { return (you + " (the latest version).", nil) }
        if let stable, isSameApp(as: stable) {
            return (you + " (the same as \(Self.display(stable.version)), the latest version).", nil)
        }
        let footnote = "Public release: " + (stable.map { Self.display($0.version) } ?? "none yet")
        if alpha == nil || !Self.isNewer(alpha!.version, than: currentVersion) {
            return (you + " (the latest alpha).", footnote)
        }
        return (you + " (an alpha, newer than the public release).", footnote)
    }

    private func offerAlpha(_ release: Release, stable: Release?) {
        NSApp.activate(ignoringOtherApps: true)
        let alphaName = Self.display(release.version)
        let a = alphaAlert(release, stable: stable)
        switch a.runModal() {
        case .alertSecondButtonReturn:
            guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let url = URL(string: dmg.browser_download_url) else {
                alert("Couldn’t update", "This alpha has no .dmg installer attached.")
                return
            }
            pendingVersion = alphaName
            install(from: url)
        case .alertThirdButtonReturn:
            if let url = URL(string: release.html_url) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    /// "Disk Alert 0.5.0 Alpha 31 is available", with Not Now as the default.
    func alphaAlert(_ release: Release, stable: Release?) -> NSAlert {
        let alphaName = Self.display(release.version)
        let a = NSAlert()
        a.messageText = "Disk Alert \(alphaName) is available"
        let publicVersion = stable.map { Self.display($0.version) } ?? "none yet"
        var text = "This is an alpha build: it hasn’t been fully tested and may be incomplete. "
        text += "You’re up to date with the public release (\(publicVersion)), so install it only if you want to try what’s coming."
        text += "\n\nYou have \(displayVersion)."
        let notes = ReleaseNotes.plain(release.body ?? "", limit: 500)
        if !notes.isEmpty { text += "\n\n" + notes }
        a.informativeText = text
        a.addButton(withTitle: "Not Now")
        a.addButton(withTitle: "Install Alpha")
        a.addButton(withTitle: "View on GitHub")
        return a
    }

    /// A version like 0.4.1 or 0.4.1-alpha.18. An alpha comes before the release it leads up to.
    struct Version: Comparable {
        let nums: [Int]
        let pre: Int?

        init(_ string: String) {
            let s = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let parts = s.split(separator: "-", maxSplits: 1)
            nums = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            pre = parts.count > 1 ? parts[1].split(separator: ".").last.flatMap { Int($0) } ?? 0 : nil
        }

        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.nums.count, b.nums.count) {
                let x = i < a.nums.count ? a.nums[i] : 0
                let y = i < b.nums.count ? b.nums[i] : 0
                if x != y { return x < y }
            }
            switch (a.pre, b.pre) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            default: return false
            }
        }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        Version(b) < Version(a)
    }

    private func offer(_ release: Release, version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Disk Alert \(Self.display(version)) is available"
        let notes = ReleaseNotes.plain(release.body ?? "")
        a.informativeText = "You have \(displayVersion)." + (notes.isEmpty ? "" : "\n\n" + notes)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "View on GitHub")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let url = URL(string: dmg.browser_download_url) else {
                state = .failed("This release has no installer.")
                alert("Couldn’t update", "This release has no .dmg installer attached.")
                return
            }
            pendingVersion = Self.display(version)
            install(from: url)
        case .alertThirdButtonReturn:
            if let url = URL(string: release.html_url) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func install(from url: URL) {
        state = .downloading
        progress = 0
        received = 0
        expected = 0
        overall = 0
        step = "Downloading…"
        showProgressWindow()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        guard state == .downloading else { return }
        downloadTask?.cancel()
        downloadSession?.invalidateAndCancel()
        state = .idle
        progress = nil
        closeProgressWindow()
    }

    // MARK: Download progress

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        received = totalBytesWritten
        expected = totalBytesExpectedToWrite
        progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        overall = 0.8 * (progress ?? 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DiskAlertUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dmg)
        } catch {
            fail("Couldn’t save the update", error.localizedDescription)
            return
        }
        installDownloaded(dmg: dmg, work: work)
    }

    /// Gets the new version ready while this one keeps running and showing progress: opens the
    /// installer, copies the new app next to this one and checks it. Only then does this version
    /// quit, leaving a quick rename and a relaunch, so the menu bar icon is gone for about a second.
    private func installDownloaded(dmg: URL, work: URL) {
        state = .installing
        progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.prepare(dmg: dmg, work: work)
            DispatchQueue.main.async {
                switch result {
                case .failure(let why):
                    try? FileManager.default.removeItem(at: Self.stagedURL)
                    self.fail("Couldn’t install the update", why.message)
                case .success(let staged):
                    self.show(step: "Restarting Disk Alert…", 1)
                    // Long enough to see the bar full before the app quits.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.swapAndRelaunch(staged: staged, work: work) }
                }
            }
        }
    }

    struct InstallError: Error { let message: String }

    /// Where the new version waits, next to this one (same disk, so moving it into place is a rename).
    /// Hidden, so it never shows up in Applications.
    static var stagedURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".Disk Alert update.app")
    }

    private func prepare(dmg: URL, work: URL) -> Result<URL, InstallError> {
        let mount = work.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        show(step: "Opening the update…", 0.84)
        let attach = DriveUsers.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                         "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else { return .failure(InstallError(message: "macOS couldn’t open the downloaded installer.")) }
        defer { DriveUsers.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else {
            return .failure(InstallError(message: "The installer has no app in it."))
        }
        let staged = Self.stagedURL
        try? FileManager.default.removeItem(at: staged)
        show(step: "Copying the new version…", 0.9)
        guard DriveUsers.run("/usr/bin/ditto", [app.path, staged.path]).status == 0 else {
            return .failure(InstallError(message: "Couldn’t copy the new version next to this one."))
        }
        show(step: "Checking it…", 0.96)
        let bundle = Bundle(url: staged)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier, let exec = bundle?.executableURL,
              FileManager.default.isExecutableFile(atPath: exec.path) else {
            return .failure(InstallError(message: "The downloaded app doesn’t look like Disk Alert."))
        }
        DriveUsers.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return .success(staged)
    }

    private func show(step text: String, _ value: Double) {
        DispatchQueue.main.async {
            self.step = text
            self.overall = value
            if UITest.isActive { print(String(format: "      (update: %@ at %.2f s)", text, Date().timeIntervalSince(self.started))) }
        }
    }

    private var started = Date()

    /// The last step, after this version quits: swap the prepared app in by renaming (instant on the
    /// same disk), put the old one back if that fails, and open the new one. It notes where it
    /// came from, so the new version can finish the progress bar with "Updated".
    private func swapAndRelaunch(staged: URL, work: URL) {
        let target = Bundle.main.bundleURL.path
        let defaults = UserDefaults.standard
        defaults.set(displayVersion, forKey: "updatedFrom")
        defaults.synchronize()
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
        launchctl bootout gui/$(id -u)/\(DiskAlert.agentLabel) 2>/dev/null || true
        rm -rf "\(target).old"
        mv "\(target)" "\(target).old"
        if mv "\(staged.path)" "\(target)"; then rm -rf "\(target).old"; else mv "\(target).old" "\(target)"; fi
        open "\(target)"
        rm -rf "\(work.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            defaults.removeObject(forKey: "updatedFrom")
            fail("Couldn’t install the update", error.localizedDescription)
        }
    }

    /// Called when the app opens: if it was just updated, shows the progress window full, with
    /// "Updated to …", for a few seconds.
    func finishUpdateIfNeeded() {
        let defaults = UserDefaults.standard
        guard let from = defaults.string(forKey: "updatedFrom") else { return }
        defaults.removeObject(forKey: "updatedFrom")
        guard from != displayVersion else {
            alert("The update didn’t finish", "Disk Alert is still \(displayVersion). Try Check for Updates again.")
            return
        }
        updatedFrom = from
        state = .updated
        overall = 1
        step = "Updated from \(from)."
        showProgressWindow()
        defaults.set(displayVersion, forKey: "lastUpdateShown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.state == .updated { self.closeProgressWindow(); self.state = .upToDate }
        }
    }

    func dismissUpdated() {
        closeProgressWindow()
        state = .upToDate
    }

    /// For the UI test: installs a local installer the same way as a downloaded one.
    func installForTest(dmg source: URL) {
        started = Date()
        pendingVersion = "test"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DiskAlertUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try? FileManager.default.copyItem(at: source, to: dmg)
        state = .downloading
        overall = 0.8
        step = "Downloaded"
        showProgressWindow()
        installDownloaded(dmg: dmg, work: work)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("Couldn’t download the update", error.localizedDescription)
    }

    private func fail(_ title: String, _ text: String) {
        state = .failed(title)
        progress = nil
        closeProgressWindow()
        alert(title, text)
    }

    // MARK: Progress window

    private func showProgressWindow() {
        if progressWindow == nil {
            // A fixed size: the content never resizes the window, so nothing can loop.
            let host = NSHostingView(rootView: UpdateProgressView(updater: self))
            host.sizingOptions = []
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            w.title = "Updating Disk Alert"
            w.styleMask = [.titled]
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.center()
            progressWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        progressWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeProgressWindow() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    var newVersion: String { pendingVersion }

    private func alert(_ title: String, _ text: String, footnote: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        Self.makeAlert(title, text, footnote: footnote).runModal()
    }

    /// An alert, with an optional small grey line under the text.
    static func makeAlert(_ title: String, _ text: String, footnote: String? = nil) -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let footnote {
            let label = NSTextField(labelWithString: footnote)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()
            a.accessoryView = label
        }
        return a
    }

    var statusText: String {
        switch state {
        case .checking: return "Checking…"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
        case .updated: return "Updated to \(displayVersion)"
        case .available(let v): return "Version \(Self.display(v)) is available"
        case .failed(let why): return why
        case .upToDate, .idle:
            if let d = lastChecked { return "Last checked " + d.formatted(.relative(presentation: .named)) }
            return "Not checked yet"
        }
    }
}

struct UpdateProgressView: View {
    @ObservedObject var updater: Updater

    private var done: Bool { updater.state == .updated }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(done ? "Updated to Disk Alert \(updater.displayVersion)" : "Updating to Disk Alert \(updater.newVersion)")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // One bar from the start of the download to the new version opening.
            ProgressView(value: updater.overall)
            HStack {
                Spacer()
                if done {
                    Button("Done") { updater.dismissUpdated() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { updater.cancelDownload() }
                        .disabled(updater.state != .downloading)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380, height: 150, alignment: .top)
    }

    private var detail: String {
        if updater.state == .downloading, updater.expected > 0 {
            return "Downloading \(Format.bytes(updater.received)) of \(Format.bytes(updater.expected))"
        }
        return updater.step
    }
}
