import Foundation

// MARK: - Identifiers and paths

enum DiskAlert {
    static let appName = "Disk Alert"
    static let agentLabel = "app.diskalert.agent"

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var settingsURL: URL { supportFolder.appendingPathComponent("settings.json") }
    static var drivesURL: URL { supportFolder.appendingPathComponent("drives.json") }
    static var historyURL: URL { supportFolder.appendingPathComponent("history.json") }
}

// MARK: - Drive categories

enum DriveCategory: String, Codable, CaseIterable, Identifiable {
    case drive, memoryCard, diskImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive: return "External drives"
        case .memoryCard: return "SD and memory cards"
        case .diskImage: return "Disk images"
        }
    }

    var detail: String {
        switch self {
        case .drive: return "SSDs, hard drives and USB sticks"
        case .memoryCard: return "Cards in the SD slot or a card reader"
        case .diskImage: return "Installers and .dmg files"
        }
    }

    var symbol: String {
        switch self {
        case .drive: return "externaldrive.fill"
        case .memoryCard: return "sdcard.fill"
        case .diskImage: return "opticaldisc.fill"
        }
    }

    /// Works out the category from what Disk Arbitration reports about the device.
    static func classify(isImage: Bool, deviceProtocol: String, model: String) -> DriveCategory {
        if isImage { return .diskImage }
        if deviceProtocol.caseInsensitiveCompare("Secure Digital") == .orderedSame { return .memoryCard }
        let m = model.lowercased()
        let cardWords = ["sd card", "sdxc", "sdhc", "card reader", "cardreader", "memory card",
                         "cfexpress", "compactflash", "microsd", "sd/mmc", "multi-card", "multicard"]
        if cardWords.contains(where: { m.contains($0) }) { return .memoryCard }
        return .drive
    }
}

// MARK: - Settings

struct DriveRule: Codable, Equatable {
    var connectSound = "Default"
    var ejectSound = "Default"

    init(connect: String = "Default", eject: String = "Default") {
        connectSound = connect
        ejectSound = eject
    }

    private enum CodingKeys: String, CodingKey { case connectSound, ejectSound, split, sound }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectSound = try c.decodeIfPresent(String.self, forKey: .connectSound) ?? "Default"
        ejectSound = try c.decodeIfPresent(String.self, forKey: .ejectSound) ?? "Default"
        // Older versions kept one sound for both unless split; carry it over.
        let split = try c.decodeIfPresent(Bool.self, forKey: .split) ?? true
        if !split, let one = try c.decodeIfPresent(String.self, forKey: .sound) {
            connectSound = one
            ejectSound = one
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectSound, forKey: .connectSound)
        try c.encode(ejectSound, forKey: .ejectSound)
    }

    /// The sound this rule picks for a connect or eject. "Default" means no opinion.
    func pick(connect: Bool) -> String { connect ? connectSound : ejectSound }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var enabled = true
    var connectSound = "Glass"
    var ejectSound = "Pop"
    var unsafeSound = "Sosumi"       // "Off" plays no sound
    var connectTitle = "Drive Connected"
    var ejectTitle = "Drive Ejected"
    var unsafeTitle = "Not Ejected Properly"
    var showInfo = true
    var openInFinder = false
    var playSoundDirectly = false    // fallback if notification sounds stay silent
    var appearance: AppearanceMode = .system
    var categoryRules: [String: DriveRule] = AppSettings.defaultCategoryRules
    var driveRules: [String: DriveRule] = [:]

    static let defaultCategoryRules: [String: DriveRule] = [DriveCategory.diskImage.rawValue: DriveRule(connect: "Purr", eject: "Purr")]

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        connectSound = try c.decodeIfPresent(String.self, forKey: .connectSound) ?? d.connectSound
        ejectSound = try c.decodeIfPresent(String.self, forKey: .ejectSound) ?? d.ejectSound
        unsafeSound = try c.decodeIfPresent(String.self, forKey: .unsafeSound) ?? d.unsafeSound
        connectTitle = try c.decodeIfPresent(String.self, forKey: .connectTitle) ?? d.connectTitle
        ejectTitle = try c.decodeIfPresent(String.self, forKey: .ejectTitle) ?? d.ejectTitle
        unsafeTitle = try c.decodeIfPresent(String.self, forKey: .unsafeTitle) ?? d.unsafeTitle
        showInfo = try c.decodeIfPresent(Bool.self, forKey: .showInfo) ?? d.showInfo
        openInFinder = try c.decodeIfPresent(Bool.self, forKey: .openInFinder) ?? d.openInFinder
        playSoundDirectly = try c.decodeIfPresent(Bool.self, forKey: .playSoundDirectly) ?? d.playSoundDirectly
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        categoryRules = try c.decodeIfPresent([String: DriveRule].self, forKey: .categoryRules) ?? d.categoryRules
        driveRules = try c.decodeIfPresent([String: DriveRule].self, forKey: .driveRules) ?? [:]
    }

    func defaultSound(connect: Bool) -> String { connect ? connectSound : ejectSound }

    /// Drive rule first, then its category, then the default sound.
    func resolvedSound(connect: Bool, driveID: String?, category: DriveCategory) -> String {
        if let id = driveID, let rule = driveRules[id] {
            let p = rule.pick(connect: connect)
            if p != "Default" { return p }
        }
        if let rule = categoryRules[category.rawValue] {
            let p = rule.pick(connect: connect)
            if p != "Default" { return p }
        }
        return defaultSound(connect: connect)
    }

    /// What "Default" means for a drive: its category's sound, else the general default.
    func fallbackSound(connect: Bool, category: DriveCategory) -> String {
        resolvedSound(connect: connect, driveID: nil, category: category)
    }
}

struct KnownDrive: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var format: String
    var capacity: Int64
    var lastSeen: Date
    var category: DriveCategory = .drive

    init(id: String, name: String, format: String, capacity: Int64, lastSeen: Date, category: DriveCategory) {
        self.id = id; self.name = name; self.format = format
        self.capacity = capacity; self.lastSeen = lastSeen; self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        capacity = try c.decodeIfPresent(Int64.self, forKey: .capacity) ?? 0
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        category = try c.decodeIfPresent(DriveCategory.self, forKey: .category) ?? .drive
    }
}

struct HistoryEvent: Codable, Equatable {
    enum Kind: String, Codable { case connected, ejected, unsafe }
    var date: Date
    var name: String
    var kind: Kind
}

// MARK: - Storage

enum Store {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var settings: AppSettings {
        load(AppSettings.self, from: DiskAlert.settingsURL) ?? AppSettings()
    }

    static var drives: [String: KnownDrive] {
        load([String: KnownDrive].self, from: DiskAlert.drivesURL) ?? [:]
    }

    static var history: [HistoryEvent] {
        load([HistoryEvent].self, from: DiskAlert.historyURL) ?? []
    }

    static func remember(_ drive: KnownDrive) {
        var all = drives
        all[drive.id] = drive
        save(all, to: DiskAlert.drivesURL)
    }

    static func log(_ event: HistoryEvent) {
        var all = history
        all.insert(event, at: 0)
        if all.count > 100 { all = Array(all.prefix(100)) }
        save(all, to: DiskAlert.historyURL)
    }
}

// MARK: - Sounds

enum Sounds {
    static let builtIn = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                          "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let extensions = ["aiff", "aif", "caf", "wav"]

    static var userFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var searchFolders: [URL] {
        [userFolder, URL(fileURLWithPath: "/Library/Sounds"), URL(fileURLWithPath: "/System/Library/Sounds")]
    }

    /// Sound files the user added, in ~/Library/Sounds.
    static var custom: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static var customNames: [String] {
        custom.map { $0.deletingPathExtension().lastPathComponent }.filter { !builtIn.contains($0) }
    }

    static var allNames: [String] { builtIn + customNames }

    static func url(for name: String) -> URL? {
        for folder in searchFolders {
            for ext in extensions {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: value)
    }
}

// MARK: - Volume info without touching files

import DiskArbitration

/// Reads volume details from Disk Arbitration and the mount list only. Neither opens or looks
/// inside the drive, so macOS has no reason to ask for permission to access removable volumes.
enum VolumeInfo {
    struct Space { let free: Int64; let total: Int64 }

    /// The system's list of mounted file systems. Reading it never opens or looks inside
    /// any drive, so macOS has no reason to ask for removable-volume access.
    private static func mountTable() -> [statfs] {
        var list: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&list, MNT_NOWAIT))
        guard count > 0, let list else { return [] }
        return (0..<count).map { list[$0] }
    }

    private static func mountPoint(of entry: statfs) -> String {
        var e = entry
        return withUnsafePointer(to: &e.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private static func space(of entry: statfs) -> Space {
        let block = Int64(entry.f_bsize)
        return Space(free: Int64(entry.f_bavail) * block, total: Int64(entry.f_blocks) * block)
    }

    /// Free and total space from the mount list, without touching the drive.
    static func space(atMountPoint path: String) -> Space? {
        mountTable().first { mountPoint(of: $0) == path }.map(space(of:))
    }

    /// Whether something is still mounted at this path, without touching the drive.
    static func isMounted(_ path: String) -> Bool {
        mountTable().contains { mountPoint(of: $0) == path }
    }

    /// Plain-English name for a file system type such as "apfs" or "exfat".
    static func formatName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "ExFAT"
        case "msdos": return "MS-DOS (FAT)"
        case "ntfs": return "NTFS"
        case "udf": return "UDF"
        case "": return ""
        default: return kind.uppercased()
        }
    }

    struct Mounted {
        let path: String
        let name: String
        let uuid: String?
        let format: String
        let space: Space?
        let isImage: Bool
        let readOnly: Bool
        let category: DriveCategory
    }

    /// External volumes mounted under /Volumes, described without reading them.
    static func mounted() -> [Mounted] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        var result: [Mounted] = []
        for var entry in mountTable() {
            let mountPoint = Self.mountPoint(of: entry)
            let device = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mountPoint.hasPrefix("/Volumes/"), device.hasPrefix("/dev/") else { continue }
            let bsd = String(device.dropFirst("/dev/".count))
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }

            let model = ((desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let proto = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
            let isImage = model == "Disk Image"
            let internalDrive = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
            let removable = (desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
            let ejectable = (desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
            if internalDrive && !isImage && !removable && !ejectable { continue }

            let name = (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? (mountPoint as NSString).lastPathComponent
            let kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String) ?? ""
            result.append(Mounted(path: mountPoint, name: name, uuid: uuid(from: desc), format: formatName(kind),
                                  space: space(of: entry), isImage: isImage,
                                  readOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0,
                                  category: DriveCategory.classify(isImage: isImage, deviceProtocol: proto, model: model)))
        }
        return result
    }

    static func uuid(from desc: [String: Any]) -> String? {
        guard let raw = desc[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID(),
              let text = CFUUIDCreateString(kCFAllocatorDefault, (raw as! CFUUID)) else { return nil }
        return text as String
    }
}
