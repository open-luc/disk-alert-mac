import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsLayout {
    static let size = CGSize(width: 580, height: 640)
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var updater = Updater.shared
    @State private var showAlphaSheet = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disk alerts").font(.headline)
                        Text(model.settings.enabled
                             ? "Watching for drives. Keeps running when the app is closed."
                             : "Paused. No alerts until you turn this back on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Disk alerts", isOn: $model.settings.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            }

            Section {
                SoundRow(title: "Connected", selection: $model.settings.connectSound)
                SoundRow(title: "Ejected", selection: $model.settings.ejectSound)
                SoundRow(title: "Unplugged without ejecting", subtitle: "Plays even for muted drives",
                         selection: $model.settings.unsafeSound, trailing: ["Off"])
            } header: {
                Text("Sounds")
            } footer: {
                Text("Move the pointer over a sound in the menu to hear it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When a drive connects") {
                Toggle(isOn: $model.settings.showInfo) {
                    Text("Show drive info")
                    Text("Free space, capacity and format in the notification")
                }
                Toggle(isOn: $model.settings.openInFinder) {
                    Text("Show in Finder automatically")
                    Text("Clicking the notification always shows the drive in Finder")
                }
            }

            Section("App") {
                Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })) {
                    Text("Open at login")
                    Text("Shows Disk Alert in the menu bar when you log in. Alerts run at login either way.")
                }
                if model.loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Needs your approval")
                        Text("Turn on Disk Alert in System Settings › General › Login Items")
                    }
                }
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            UpdatesSection()

            Section {
                HStack {
                    Button("Send Test Alert") { AgentControl.sendTest() }
                    Spacer()
                    Button("Uninstall Disk Alert…", role: .destructive) { model.uninstall() }
                }
            } footer: {
                HStack {
                    Text("Version \(updater.displayVersion)")
                    Spacer()
                    // Kept small and quiet on purpose: alphas are for people who go looking.
                    Button(updater.alphaOptIn ? "Alpha builds: On" : "Alpha builds…") { showAlphaSheet = true }
                        .buttonStyle(.plain)
                        .help("Early, untested versions of Disk Alert")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
        .sheet(isPresented: $showAlphaSheet) { AlphaBuildsSheet(updater: updater) }
    }
}

/// Explains alpha builds before anyone turns them on.
struct AlphaBuildsSheet: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "flask")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alpha Builds").font(.headline)
                    Text("Early versions of Disk Alert").font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("Alpha builds are previews of upcoming changes, published before they reach the public release. They haven’t been fully tested, may be incomplete, and can change or stop working between builds. They aren’t recommended for everyday use.")
                .fixedSize(horizontal: false, vertical: true)

            Text("With this on, Check for Updates also tells you when a newer alpha is available. Alphas are never installed for you: each one is offered only when you check by hand, and only installs if you choose Install Alpha. Automatic checks still only offer public releases.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Toggle(isOn: $updater.alphaOptIn) {
                Text("Offer alpha builds")
            }
            .toggleStyle(.switch)
            .padding(.vertical, 4)

            Text(updater.isAlpha
                 ? "You’re running \(updater.displayVersion). To go back, turn this off: the next public release will be offered as a normal update."
                 : "Turning this off later keeps whatever version you have. If you’re on an alpha, the next public release replaces it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct UpdatesSection: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent {
                Button("Check for Updates") { updater.check(userInitiated: true) }
                    .disabled(updater.state == .checking || updater.state == .downloading)
            } label: {
                Text("Disk Alert \(updater.displayVersion)")
                Text(updater.statusText)
            }
            Toggle(isOn: $updater.automatic) {
                Text("Check automatically")
                Text("Once a day. You’re always asked before anything installs.")
            }
        }
    }
}

// MARK: - Drives

/// A drive or drive type: its name, then a Connected and an Ejected sound menu.
struct RuleBlock: View {
    @EnvironmentObject var model: AppModel
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var rule: DriveRule
    var defaultConnect: String
    var defaultEject: String
    var onForget: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let onForget {
                Spacer()
                Button(action: onForget) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Forget this drive")
                .accessibilityLabel("Forget \(title)")
            }
        }
        SoundRow(title: "Connected", selection: $rule.connectSound,
                 leading: ["Default"], trailing: ["Mute"], defaultSound: defaultConnect)
        SoundRow(title: "Ejected", selection: $rule.ejectSound,
                 leading: ["Default"], trailing: ["Mute"], defaultSound: defaultEject)
    }
}

struct DrivesTab: View {
    @EnvironmentObject var model: AppModel
    /// Drives start collapsed each time Settings opens.
    @State var expanded: Set<String> = []
    /// Starts scrolled to the bottom. Used for screenshots of "Your Drives".
    var startAtBottom = false

    var body: some View {
        Form {
            ForEach(Array(DriveCategory.allCases.enumerated()), id: \.element) { i, c in
                Section {
                    RuleBlock(symbol: c.symbol, title: c.title, subtitle: c.detail,
                              rule: model.ruleBinding(forCategory: c),
                              defaultConnect: model.settings.connectSound,
                              defaultEject: model.settings.ejectSound)
                } header: {
                    if i == 0 { Text("Drive types") }
                } footer: {
                    if i == DriveCategory.allCases.count - 1 {
                        Text("“Default” follows the sounds in General. SD cards are recognized in the built-in slot and most card readers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if model.drives.isEmpty {
                    Text("Drives show up here after they connect once.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.drives) { drive in
                        DriveRow(drive: drive, expanded: expandedBinding(drive.id), onForget: { confirmForget(drive) })
                    }
                }
            } header: {
                yourDrivesHeader
            } footer: {
                if !model.drives.isEmpty {
                    Text("Click a drive to change its sounds. “Default” follows the drive’s type, then General. “Mute” silences that alert. The − button forgets a drive and its sounds; it comes back the next time it’s plugged in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(startAtBottom ? .bottom : .top)
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
    }

    /// Set apart from the drive types above by a rule, a larger title and a count.
    private var yourDrivesHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.top, 10)
                .padding(.bottom, 18)
            HStack(alignment: .firstTextBaseline) {
                Text("Your Drives")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                if !model.drives.isEmpty {
                    Text("\(model.drives.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                if !model.drives.isEmpty {
                    Button(expanded.isEmpty ? "Expand All" : "Collapse All") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expanded = expanded.isEmpty ? Set(model.drives.map(\.id)) : []
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            Text("Sounds for one specific drive. These override the drive types above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.bottom, 4)
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                withAnimation(.easeInOut(duration: 0.15)) {
                    if open { expanded.insert(id) } else { expanded.remove(id) }
                }
            }
        )
    }

    private func confirmForget(_ drive: KnownDrive) {
        let a = NSAlert()
        a.messageText = "Forget “\(drive.name)”?"
        a.informativeText = "Its sounds go back to Default and it leaves this list. It shows up again the next time you plug it in."
        a.addButton(withTitle: "Forget")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { model.forgetDrive(drive.id) }
    }
}

/// One remembered drive: a single row that opens to show its sound pickers.
struct DriveRow: View {
    @EnvironmentObject var model: AppModel
    let drive: KnownDrive
    @Binding var expanded: Bool
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: drive.category.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(drive.name)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !expanded {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(drive.name)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the sounds for this drive")

            Button(action: onForget) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Forget this drive")
            .accessibilityLabel("Forget \(drive.name)")
        }
        if expanded {
            let rule = model.ruleBinding(forDrive: drive.id)
            SoundRow(title: "Connected", selection: rule.connectSound,
                     leading: ["Default"], trailing: ["Mute"],
                     defaultSound: model.settings.fallbackSound(connect: true, category: drive.category))
                .padding(.leading, 22)
            SoundRow(title: "Ejected", selection: rule.ejectSound,
                     leading: ["Default"], trailing: ["Mute"],
                     defaultSound: model.settings.fallbackSound(connect: false, category: drive.category))
                .padding(.leading, 22)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !drive.format.isEmpty { parts.append(drive.format) }
        if drive.capacity > 0 { parts.append(Format.bytes(drive.capacity)) }
        parts.append("seen " + drive.lastSeen.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    /// The drive's own sounds at a glance, e.g. "Hero · Default", or "Default sounds".
    private var summary: String {
        let rule = model.settings.driveRules[drive.id] ?? DriveRule()
        if rule.connectSound == "Default" && rule.ejectSound == "Default" { return "Default sounds" }
        return "\(rule.connectSound) · \(rule.ejectSound)"
    }
}

// MARK: - Sounds

struct SoundsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var dropping = false

    var body: some View {
        Form {
            Section {
                if model.customSounds.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No sounds added yet")
                            .font(.headline)
                        Text("Drag any audio file here, or click Add Sound.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(model.customSounds, id: \.self) { name in
                        HStack(spacing: 10) {
                            Button { SoundPreview.play(name) } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play \(name)")
                            Text(name)
                            Spacer()
                            if model.bundledSounds.contains(name) {
                                Text("Included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            } else {
                                Button("Delete…", role: .destructive) { model.confirmDeleteSound(name) }
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Custom sounds")
                    Spacer()
                    Button("Add Sound…") { model.chooseSounds() }
                }
            } footer: {
                HStack {
                    Text("Saved in ~/Library/Sounds and converted so notifications can play them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { model.showSoundsFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(14)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addSound(from: url) }
                }
            }
            return true
        }
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
    }
}
