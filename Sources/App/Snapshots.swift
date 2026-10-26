import AppKit
import SwiftUI

/// Draws the real Settings tabs and menu bar window with sample data and saves them as PNGs
/// for the README. Run with: DiskAlert --snapshots <folder>
enum Snapshots {
    static let isActive = CommandLine.arguments.contains("--snapshots")

    static var outputFolder: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1])
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("screenshots")
    }

    static func run() {
        let model = AppModel.shared
        let out = outputFolder
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for (suffix, look) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: look)
            render(GeneralTab().environmentObject(model), title: "General", to: out.appendingPathComponent("settings-general-\(suffix).png"), look: look)
            render(DrivesTab().environmentObject(model), title: "Drives", to: out.appendingPathComponent("settings-drives-\(suffix).png"), look: look)
            render(DrivesTab(expanded: ["b"], startAtBottom: true).environmentObject(model), title: "Drives",
                   to: out.appendingPathComponent("settings-your-drives-\(suffix).png"), look: look)
            render(AlphaBuildsSheet(updater: Updater.shared), title: nil,
                   to: out.appendingPathComponent("alpha-builds-\(suffix).png"), look: look)
            render(SoundsTab().environmentObject(model), title: "Custom Sounds", to: out.appendingPathComponent("settings-sounds-\(suffix).png"), look: look)
            render(MenuView().environmentObject(model), title: nil, to: out.appendingPathComponent("menu-\(suffix).png"), look: look)
        }
        print("Snapshots written to \(out.path)")
        exit(0)
    }

    /// Lays the view out in an offscreen window, captures it at 2x, and frames it
    /// with rounded corners, an optional title bar and a soft shadow.
    private static func render<V: View>(_ view: V, title: String?, to url: URL, look: NSAppearance.Name) {
        let appearance = NSAppearance(named: look)
        let dark = look == .darkAqua
        // An explicit background in the matching look. Without it, views that have no
        // background of their own (the menu) are captured over a white backdrop in Dark mode.
        let surface = dark ? Color(white: 0.16) : Color(white: 0.97)
        let root = view
            .background(surface)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let content = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        content.size = size
        host.cacheDisplay(in: host.bounds, to: content)
        window.orderOut(nil)

        let titleHeight: CGFloat = title == nil ? 0 : 52
        let margin: CGFloat = 40
        let frameSize = NSSize(width: size.width, height: size.height + titleHeight)
        let canvas = NSSize(width: frameSize.width + margin * 2, height: frameSize.height + margin * 2)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let frameRect = NSRect(x: margin, y: margin, width: frameSize.width, height: frameSize.height)
        let radius: CGFloat = title == nil ? 16 : 14
        let shape = NSBezierPath(roundedRect: frameRect, xRadius: radius, yRadius: radius)

        // Shadow
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        content.draw(in: NSRect(x: margin, y: margin, width: size.width, height: size.height))

        if let title {
            let bar = NSRect(x: margin, y: margin + size.height, width: size.width, height: titleHeight)
            (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            bar.fill()
            (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).setFill()
            NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1).fill()
            for (i, c) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                           NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                           NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: bar.minX + 18 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.15, alpha: 1)
            ]
            let text = NSAttributedString(string: "Disk Alert · \(title)", attributes: attrs)
            let t = text.size()
            text.draw(at: NSPoint(x: bar.midX - t.width / 2, y: bar.midY - t.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()

        // Hairline border
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
