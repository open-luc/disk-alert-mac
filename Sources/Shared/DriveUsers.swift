import AppKit
import DiskArbitration

/// Something keeping a drive from ejecting, grouped the way people think about it: by app.
/// A shell running in Terminal counts as Terminal, and an app with 30 files open is one entry.
struct DriveUser: Identifiable, Equatable {
    enum Kind: Equatable {
        case app       // a regular app; Quit Apps & Eject can quit it
        case process   // a program with no app around it, such as a command-line tool
        case macOS     // part of macOS, such as Spotlight indexing or a Time Machine backup
    }

    let id: pid_t        // the app's process, or the process itself
    let name: String
    let kind: Kind
    let detail: String
    var appPath: String? = nil

    var canQuit: Bool { kind == .app }
}

enum DriveUsers {
    /// Who has files open on the volume mounted at `mountPoint`, apps first and macOS last.
    /// Processes macOS runs as root (most of Spotlight, Time Machine) are hidden from apps, so a
    /// drive can be busy with nothing listed: that is macOS using it.
    static func scan(mountPoint: String) -> [DriveUser] {
        let me = ProcessInfo.processInfo.processIdentifier
        var groups: [pid_t: Group] = [:]
        for entry in openFiles(onVolume: mountPoint) where entry.pid != me {
            let owner = Self.owningApp(of: entry.pid)
            let key = owner?.processIdentifier ?? entry.pid
            if groups[key] == nil {
                groups[key] = Group(app: owner, command: entry.command, pid: entry.pid)
            }
            groups[key]?.add(entry)
        }
        let order: [DriveUser.Kind: Int] = [.app: 0, .process: 1, .macOS: 2]
        return groups.values.map { $0.user }.sorted {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Open files

    struct OpenFile {
        let pid: pid_t
        let command: String
        let fd: String     // a number, or "cwd" (working folder) or "txt" (the program itself)
        let path: String
    }

    /// Asks lsof, which comes with macOS, for every file open on the volume. Given a mount
    /// point it lists the whole file system without walking it, so this is quick.
    static func openFiles(onVolume mountPoint: String) -> [OpenFile] {
        let out = run("/usr/sbin/lsof", ["-w", "-n", "-P", "-F", "pcfn", "--", mountPoint]).output
        var result: [OpenFile] = []
        var pid: pid_t = 0, command = "", fd = ""
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = pid_t(value) ?? 0; command = ""; fd = ""
            case "c": command = value
            case "f": fd = value
            case "n": if pid > 0 { result.append(OpenFile(pid: pid, command: command, fd: fd, path: value)) }
            default: break
            }
        }
        return result
    }

    // MARK: Grouping

    private struct Group {
        let app: NSRunningApplication?
        let command: String
        let pid: pid_t
        var files: Set<String> = []
        var workingFolder = false
        var runningFromDrive = false

        mutating func add(_ e: OpenFile) {
            switch e.fd {
            case "cwd": workingFolder = true
            case "txt": runningFromDrive = true
            default: files.insert(e.path)
            }
        }

        var user: DriveUser {
            if let app {
                return DriveUser(id: app.processIdentifier, name: app.localizedName ?? command, kind: .app,
                                 detail: detail, appPath: app.bundleURL?.path)
            }
            if let service = DriveUsers.macOSService(command: command, pid: pid) {
                return DriveUser(id: pid, name: "macOS (\(service.name))", kind: .macOS, detail: service.detail)
            }
            return DriveUser(id: pid, name: command, kind: .process, detail: detail)
        }

        private var detail: String {
            switch files.count {
            case 0:
                if workingFolder { return "Working in a folder on this drive" }
                if runningFromDrive { return "Running from this drive" }
                return "Using this drive"
            case 1:
                return "“\((files.first! as NSString).lastPathComponent)” is open"
            default:
                return "\(files.count) files open"
            }
        }
    }

    /// The app a process belongs to: itself, or the nearest app above it (zsh in Terminal → Terminal).
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<16 {
            guard let p = current else { return nil }
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy != .prohibited, app.bundleURL != nil {
                return app
            }
            current = parent(of: p)
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// Processes named in diskutil's reason for a failed eject ("dissented by PID 312
    /// (/System/Library/…/mds)"). This can name ones the scan can't see, such as Spotlight
    /// running as root.
    static func dissenters(inEjectError text: String) -> [DriveUser] {
        guard let regex = try? NSRegularExpression(pattern: #"dissented by PID (\d+) \(([^)]*)\)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard let pidRange = Range(m.range(at: 1), in: text), let pid = pid_t(text[pidRange]), pid > 0,
                  let pathRange = Range(m.range(at: 2), in: text) else { return nil }
            let command = (String(text[pathRange]) as NSString).lastPathComponent
            if let app = owningApp(of: pid) {
                return DriveUser(id: app.processIdentifier, name: app.localizedName ?? command, kind: .app,
                                 detail: "Using this drive", appPath: app.bundleURL?.path)
            }
            if let service = macOSService(command: command, pid: pid) {
                return DriveUser(id: pid, name: "macOS (\(service.name))", kind: .macOS, detail: service.detail)
            }
            return DriveUser(id: pid, name: command, kind: .process, detail: "Using this drive")
        }
    }

    /// Parts of macOS that use drives on their own. They can't be quit, and usually finish soon.
    static func macOSService(command: String, pid: pid_t) -> (name: String, detail: String)? {
        let spotlight = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd"]
        if spotlight.contains(command) { return ("Spotlight", "Indexing this drive. Try again in a moment.") }
        if command.hasPrefix("backupd") { return ("Time Machine", "Backing up to this drive") }
        if command.lowercased().contains("quicklook") { return ("Quick Look", "Making previews. Try again in a moment.") }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
                return (command, "Using this drive. Try again in a moment.")
            }
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Ejecting a drive even while apps are using it.
enum ForceEject {
    /// Posted before a forced eject so the agent counts it as an eject, not an unplug.
    /// The object is the volume's mount point.
    static let notice = Notification.Name("app.diskalert.forceEject")

    /// Unmounts the drive even with files open on it, then ejects it. macOS still finishes writing
    /// what it had and closes the drive properly; the apps keep running without access to it.
    /// Returns nil when done, or what went wrong.
    static func run(mountPoint: String) -> String? {
        let disk = VolumeInfo.wholeDisk(atMountPoint: mountPoint)
        DistributedNotificationCenter.default().postNotificationName(
            notice, object: mountPoint, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.3)   // let the agent note it before the drive goes

        let unmount = DriveUsers.run("/usr/sbin/diskutil", ["unmountDisk", "force", disk ?? mountPoint])
        guard unmount.status == 0 else {
            let why = unmount.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return why.isEmpty ? "macOS couldn’t unmount it." : why
        }
        // Unmounted is already safe to unplug; ejecting also powers the drive down where it can.
        if let disk { DriveUsers.run("/usr/sbin/diskutil", ["eject", disk]) }
        return nil
    }
}
