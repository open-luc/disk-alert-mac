import Cocoa
import DiskArbitration
import UserNotifications

// The background agent. It runs as a tiny, windowless process started by launchd,
// watches drives with Disk Arbitration and posts the notifications. It keeps running
// when the Disk Alert menu bar app is closed.

struct Volume {
    let bsd: String
    let id: String
    let name: String
    let url: URL
    let format: String
    let category: DriveCategory
}

enum Event { case connect, eject, unsafe }

final class Monitor: NSObject, UNUserNotificationCenterDelegate {
    private var session: DASession?
    private var mounted: [String: Volume] = [:]      // keyed by BSD name, e.g. disk5s1
    private var ejectRequested: Set<String> = []
    private var ready = false
    private var players: [NSSound] = []

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, kDADiskDescriptionWatchVolumePath.takeUnretainedValue(), { disk, _, ctx in
            Monitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).disappeared(disk)
        }, ctx)
        // Called when anything asks the system to unmount a volume (Finder eject,
        // the Disk Alert menu, diskutil). Pulling the cable never asks, which is how
        // an unsafe removal is told apart from a proper eject.
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).unmountRequested(disk)
            return nil
        }, ctx)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Drives already plugged in when the agent starts are noted silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.ready = true }
    }

    static func from(_ ctx: UnsafeMutableRawPointer?) -> Monitor {
        Unmanaged<Monitor>.fromOpaque(ctx!).takeUnretainedValue()
    }

    // MARK: Disk events

    private func bsdName(_ disk: DADisk) -> String? {
        guard let c = DADiskGetBSDName(disk) else { return nil }
        return String(cString: c)
    }

    private func volume(for disk: DADisk) -> Volume? {
        guard let bsd = bsdName(disk),
              let desc = DADiskCopyDescription(disk) as? [String: Any],
              let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL,
              url.path.hasPrefix("/Volumes/") else { return nil }

        let model = ((desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let proto = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        let isImage = model == "Disk Image"

        // A built-in SD card slot reports as an internal device, so internal media still
        // counts when it is removable or ejectable. Only fixed internal disks are skipped.
        let internalDrive = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
        let removable = (desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
        let ejectable = (desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
        if internalDrive && !isImage && !removable && !ejectable { return nil }

        let name = (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? url.lastPathComponent
        let id = VolumeInfo.uuid(from: desc) ?? name
        let kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String) ?? ""
        let category = DriveCategory.classify(isImage: isImage, deviceProtocol: proto, model: model)
        return Volume(bsd: bsd, id: id, name: name, url: url, format: VolumeInfo.formatName(kind), category: category)
    }

    func update(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        if let vol = volume(for: disk) {
            if mounted[bsd] == nil {
                mounted[bsd] = vol
                if ready { fire(.connect, vol) }
            }
        } else if let vol = mounted.removeValue(forKey: bsd) {
            // The volume is no longer mounted.
            let proper = ejectRequested.remove(bsd) != nil || vol.category == .diskImage
            fire(proper ? .eject : .unsafe, vol)
        }
    }

    func disappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        ejectRequested.remove(bsd)
        if let vol = mounted.removeValue(forKey: bsd) {
            // Gone while still mounted: unplugged without ejecting.
            fire(vol.category == .diskImage ? .eject : .unsafe, vol)
        }
    }

    func unmountRequested(_ disk: DADisk) {
        if let bsd = bsdName(disk) { ejectRequested.insert(bsd) }
    }

    // MARK: Notifications

    private func details(_ vol: Volume) -> (info: String, format: String, total: Int64) {
        let space = VolumeInfo.space(atMountPoint: vol.url.path)
        let total = space?.total ?? 0
        let free = space?.free ?? 0
        let format = vol.format
        var parts: [String] = []
        if total > 0 { parts.append("\(Format.bytes(free)) free of \(Format.bytes(total))") }
        if !format.isEmpty { parts.append(format) }
        return (parts.joined(separator: " · "), format, total)
    }

    func fire(_ event: Event, _ vol: Volume) {
        let s = Store.settings
        guard s.enabled else { return }

        var body = ""
        switch event {
        case .connect:
            let d = details(vol)
            if vol.category != .diskImage {
                Store.remember(KnownDrive(id: vol.id, name: vol.name, format: d.format, capacity: d.total,
                                          lastSeen: Date(), category: vol.category))
            }
            if s.showInfo { body = d.info }
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .connected))
        case .eject:
            body = "Safe to unplug"
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .ejected))
        case .unsafe:
            body = "Unplugged \(Self.stamp(Date())) without ejecting. Files may be damaged."
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .unsafe))
        }

        // Sound: an unplugged warning always uses its own sound, even for a muted drive.
        let soundName: String
        if event == .unsafe {
            soundName = s.unsafeSound
        } else {
            soundName = s.resolvedSound(connect: event == .connect, driveID: vol.id, category: vol.category)
            if soundName == "Mute" { return }
        }

        let content = UNMutableNotificationContent()
        switch event {
        case .connect: content.title = s.connectTitle
        case .eject: content.title = s.ejectTitle
        case .unsafe: content.title = s.unsafeTitle
        }
        content.subtitle = vol.name
        content.body = body
        var info: [String: Any] = ["drive": vol.id, "kind": Self.kind(event)]
        if event == .connect { info["path"] = vol.url.path }
        content.userInfo = info

        if soundName != "Off", let file = Sounds.url(for: soundName) {
            if s.playSoundDirectly {
                play(file)
            } else {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent))
            }
        }

        post(content, replacingFor: event == .unsafe ? nil : vol.id)

        if event == .connect && s.openInFinder {
            showInFinder(vol.url)
        }
    }

    private static func kind(_ event: Event) -> String {
        switch event {
        case .connect: return "connect"
        case .eject: return "eject"
        case .unsafe: return "unsafe"
        }
    }

    /// "on Oct 26 at 3:42 PM", in the user's own date and time format.
    private static func stamp(_ date: Date) -> String {
        "on \(date.formatted(.dateTime.month(.abbreviated).day())) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Posts a notification. With a drive ID, that drive's earlier "connected" and "ejected"
    /// notifications are cleared first, so Notification Center keeps only its latest one.
    /// "Unplugged" warnings are never cleared, and nothing from before the drive's most recent
    /// warning is either, so a drive that keeps dropping out leaves its whole trail.
    private func post(_ content: UNMutableNotificationContent, replacingFor driveID: String? = nil) {
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        guard let driveID else {
            center.add(request) { _ in }
            return
        }
        center.getDeliveredNotifications { delivered in
            let mine = delivered.filter { $0.request.content.userInfo["drive"] as? String == driveID }
            let lastWarning = mine
                .filter { $0.request.content.userInfo["kind"] as? String == "unsafe" }
                .map(\.date).max() ?? .distantPast
            let stale = mine
                .filter { $0.request.content.userInfo["kind"] as? String != "unsafe" && $0.date > lastWarning }
                .map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            center.add(request) { _ in }
        }
    }

    private func play(_ url: URL) {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        players.append(sound)
        if players.count > 8 { players.removeFirst() }
        sound.play()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Opens a Finder window with the drive selected. Opening the drive itself would count as
    /// reading it, and macOS would ask for removable-volume access.
    private func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Clicking a "connected" notification shows the drive in Finder.
    /// Other notifications open Disk Alert's settings.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        if let path = response.notification.request.content.userInfo["path"] as? String,
           VolumeInfo.isMounted(path) {
            showInFinder(URL(fileURLWithPath: path))
        } else {
            openMainApp()
        }
    }

    private func openMainApp() {
        // The agent lives at Disk Alert.app/Contents/Library/LoginItems/Disk Alert Agent.app
        let main = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if main.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: main, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Test

    func sendTest() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                let s = Store.settings
                let content = UNMutableNotificationContent()
                content.title = s.connectTitle
                content.subtitle = "Test Drive"
                content.body = "This is how alerts will look."
                if let file = Sounds.url(for: s.connectSound) {
                    if s.playSoundDirectly { self.play(file) }
                    else { content.sound = UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent)) }
                }
                self.post(content)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let monitor = Monitor()
if CommandLine.arguments.contains("--test") {
    monitor.sendTest()
} else {
    monitor.start()
}
app.run()
