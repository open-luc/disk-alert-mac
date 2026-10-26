import AppKit
import Foundation
import SwiftUI

/// Checks GitHub Releases for a newer Disk Alert and installs it.
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    static let repo = "open-luc/disk-alert-mac"

    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }

    @Published var state: State = .idle
    @Published var progress: Double? = nil          // 0...1 while downloading, nil when unknown
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var progressWindow: NSWindow?
    private var pendingVersion = ""
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

        // A newer public release always comes first.
        if let stable, Self.isNewer(stable.version, than: currentVersion) {
            state = .available(stable.version)
            offer(stable, version: stable.version)
            return
        }
        state = .upToDate
        guard userInitiated else { return }

        let versions = versionSummary(stable: stable, alpha: alpha)
        // Alphas are offered only when asked, and never pushed: OK is the default.
        if alphaOptIn, let alpha, Self.isNewer(alpha.version, than: currentVersion) {
            offerAlpha(alpha, versions: versions)
            return
        }
        alert("You’re up to date", versions)
    }

    /// Which version you have, and the newest public release and alpha, one per line.
    /// The alpha line only shows once alpha builds are turned on.
    private func versionSummary(stable: Release?, alpha: Release?) -> String {
        var lines = ["You have: \(displayVersion)"]
        lines.append("Latest public release: " + (stable.map { Self.display($0.version) } ?? "none"))
        if alphaOptIn {
            lines.append("Latest alpha: " + (alpha.map { Self.display($0.version) } ?? "none"))
        }
        return lines.joined(separator: "\n")
    }

    private func offerAlpha(_ release: Release, versions: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alphaName = Self.display(release.version)
        let a = NSAlert()
        a.messageText = "You’re up to date"
        var text = versions
        text += "\n\nYou can install \(alphaName) if you like. Alpha builds haven’t been fully tested and may be incomplete."
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 500 { notes = String(notes.prefix(500)) + "…" }
        if !notes.isEmpty { text += "\n\n" + notes }
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Install Alpha")
        a.addButton(withTitle: "View on GitHub")
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
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        a.informativeText = "You have \(displayVersion).\n\n" + (notes.isEmpty ? "" : notes)
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
        state = .installing
        progress = nil
        // Let the window show "Installing…" for a moment before the app quits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.replaceAndRelaunch(dmg: dmg, work: work) }
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
            let host = NSHostingController(rootView: UpdateProgressView(updater: self))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
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

    /// Hands the swap to a small script that waits for this app to quit, replaces it, and opens the new one.
    private func replaceAndRelaunch(dmg: URL, work: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
        set -e
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        MNT="\(work.path)/mnt"
        mkdir -p "$MNT"
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "\(dmg.path)" >/dev/null
        APP="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
        launchctl bootout gui/$(id -u)/\(DiskAlert.agentLabel) 2>/dev/null || true
        rm -rf "\(target).old"
        mv "\(target)" "\(target).old"
        if ditto "$APP" "\(target)"; then rm -rf "\(target).old"; else mv "\(target).old" "\(target)"; fi
        hdiutil detach "$MNT" -quiet || true
        xattr -dr com.apple.quarantine "\(target)" 2>/dev/null || true
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
            fail("Couldn’t install the update", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    var statusText: String {
        switch state {
        case .checking: return "Checking…"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating to Disk Alert \(updater.newVersion)")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let p = updater.progress, updater.state == .downloading {
                ProgressView(value: p)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel") { updater.cancelDownload() }
                    .disabled(updater.state != .downloading)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var detail: String {
        switch updater.state {
        case .installing:
            return "Installing… Disk Alert will reopen by itself."
        default:
            if updater.expected > 0 {
                return "Downloading \(Format.bytes(updater.received)) of \(Format.bytes(updater.expected))"
            }
            return "Downloading…"
        }
    }
}
