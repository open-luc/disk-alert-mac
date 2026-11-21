import AppKit
import ServiceManagement
import SwiftUI

@main
struct DiskAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.settings.enabled ? "externaldrive.fill" : "externaldrive")
                .accessibilityLabel("Disk Alert")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) weak var shared: AppDelegate?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if Snapshots.isActive {
            Snapshots.run()
            return
        }
        if UITest.isActive {
            UITest.run()
            return
        }
        if UITest.updateTestDMG != nil {
            UITest.runUpdate()
            return
        }
        AppModel.shared.applyAppearance()
        AppModel.shared.installBundledSounds()
        Updater.shared.startAutomaticChecks()
        Updater.shared.finishUpdateIfNeeded()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            showSettings()
        } else if AppModel.shared.restoreMenuBarIcon() {
            // Opened after the icon was hidden: it's back, and Settings shows where things are.
            showSettings()
        }
        // Open at login starts on. Applied once, so turning it off later sticks.
        if !defaults.bool(forKey: "openAtLoginDefaultApplied") {
            defaults.set(true, forKey: "openAtLoginDefaultApplied")
            if SMAppService.mainApp.status != .enabled { AppModel.shared.setOpenAtLogin(true) }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settingsWindow == nil {
            let model = AppModel.shared
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = false

            func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
                let host = NSHostingController(rootView: view.environmentObject(model))
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            add("General", "gearshape", GeneralTab())
            add("Drives", "externaldrive", DrivesTab())
            add("Custom Sounds", "speaker.wave.2", SoundsTab())

            let window = NSWindow(contentViewController: tabs)
            window.title = "Disk Alert"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(SettingsLayout.size)
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Back to a menu bar only app (no Dock icon) once Settings closes.
    func windowWillClose(_ notification: Notification) {
        SoundPreview.stop()
        NSApp.setActivationPolicy(.accessory)
    }
}
