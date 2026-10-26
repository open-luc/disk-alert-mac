import AppKit
import SwiftUI

/// The menu bar window, laid out like Control Center: a header module,
/// drive tiles, then plain menu-style rows.
struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.mountedVolumes.isEmpty {
                sectionTitle("Connected")
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("No drives connected")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .moduleBackground()
            } else {
                // Real drives get the big tiles; disk images sit in their own slimmer list below.
                let drives = model.mountedVolumes.filter { $0.category != .diskImage }
                let images = model.mountedVolumes.filter { $0.category == .diskImage }
                if !drives.isEmpty {
                    sectionTitle("Drives")
                    VStack(spacing: 6) {
                        ForEach(drives) { v in
                            DriveTile(volume: v)
                        }
                    }
                }
                if !images.isEmpty {
                    sectionTitle("Disk Images")
                    VStack(spacing: 0) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { i, v in
                            if i > 0 { Divider().padding(.leading, 40).padding(.trailing, 8) }
                            DiskImageRow(volume: v)
                        }
                    }
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
                }
            }

            Divider().padding(.horizontal, 6).padding(.top, 2)

            VStack(spacing: 0) {
                if model.mountedVolumes.count > 1 {
                    MenuRow(title: "Eject All…", symbol: "eject") { model.ejectAll() }
                }
                MenuRow(title: "Check for Updates…", symbol: "arrow.down.circle") {
                    Updater.shared.check(userInitiated: true)
                }
                MenuRow(title: "Settings…", symbol: "gearshape", key: ",") {
                    AppDelegate.shared?.showSettings()
                }
                MenuRow(title: "Hide Menu Bar Icon", symbol: "eye.slash",
                        detail: "Alerts keep running", key: "h") {
                    model.hideMenuBarIcon()
                }
            }
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.settings.enabled ? Color.accentColor : Color.secondary.opacity(0.35))
                Image(systemName: model.settings.enabled ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Disk Alert").font(.headline)
                Text(model.settings.enabled ? "Watching for drives" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Disk alerts", isOn: $model.settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(12)
        .moduleBackground()
    }
}

struct DriveTile: View {
    @EnvironmentObject var model: AppModel
    let volume: MountedVolume
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volume.category.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if volume.total > 0 {
                    ProgressView(value: volume.usedFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(volume.usedFraction > 0.9 ? .orange : .accentColor)
                    Text("\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.eject(volume)
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .modernCircleButton()
            .help("Eject \(volume.name)")
            .accessibilityLabel("Eject \(volume.name)")
        }
        .padding(10)
        .moduleBackground()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
        .help("Double-click to show in Finder")
    }
}

/// A disk image: one slim row with an indigo disc, so it reads as different from a real drive.
struct DiskImageRow: View {
    @EnvironmentObject var model: AppModel
    let volume: MountedVolume

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.indigo)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                model.eject(volume)
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Eject \(volume.name)")
            .accessibilityLabel("Eject \(volume.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
        .help("Double-click to show in Finder")
    }

    /// Installers are read-only, so their size is all that matters. Writable images
    /// (some grow as they fill) show free space like a drive.
    private var detail: String {
        if volume.readOnly { return "Read-only · \(Format.bytes(volume.total))" }
        guard volume.total > 0 else { return "Disk image" }
        return "\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))"
    }
}

/// A row that highlights on hover like a native menu item.
struct MenuRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    /// A Command-key shortcut that works while the menu is open, e.g. "," for ⌘,
    var key: KeyEquivalent? = nil
    let action: () -> Void

    private var shortcut: String? { key.map { "⌘" + String($0.character).uppercased() } }
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(hovering ? Color.white : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                    }
                }
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CommandShortcut(key: key))
        .onHover { hovering = $0 }
    }
}

/// Adds a Command-key shortcut only when the row has one.
struct CommandShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}

// MARK: - Styling

extension View {
    /// The rounded "module" behind each group, like Control Center tiles.
    func moduleBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Liquid Glass circular button on macOS 26 and later, a plain circle before that.
    @ViewBuilder
    func modernCircleButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.borderless)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
    }
}
