# Disk Alert

A lightweight macOS menu bar app that notifies you when drives connect, eject, or get unplugged without ejecting. Custom sounds per drive, drive info at a glance, and alerts that keep running even when the app is closed.

## Features

- **Connect, eject and unplugged alerts.** A native notification with the drive's name, and a separate warning when a drive is pulled out without ejecting first.
- **Tidy Notification Center.** Each drive keeps only its latest "connected" or "ejected" notification. "Unplugged" warnings stay until you dismiss them, with the date and time it happened, so a drive that keeps dropping out leaves a trail.
- **Drive info.** Free space, capacity and format right in the notification.
- **Drive types.** External drives, SD and memory cards, and disk images are recognized separately, each with its own sound or mute.
- **Sounds per drive.** Give each drive its own sound, split it into separate connect and eject sounds, or mute it.
- **Hear sounds as you browse.** Move the pointer through a sound menu and each one plays, like System Settings.
- **Click to show.** Clicking a "connected" notification shows the drive in Finder.
- **Your own sounds.** Drag in any audio file. It is converted and saved to `~/Library/Sounds`.
- **Menu bar.** See connected drives with free space, eject one, or eject all (with two confirmations).
- **Show in Finder** when a drive connects (optional).
- **Hide the menu bar icon** if you only want the alerts. Open Disk Alert again to bring it back.
- **Light, Dark or System appearance.**
- **Opens at login** in the menu bar (can be turned off in Settings).
- **Respects Focus and Do Not Disturb**, like any other Mac notification.
- **Updates itself.** Check for Updates in the menu bar or Settings installs the newest release from GitHub. Older versions stay available on the [Releases page](https://github.com/open-luc/disk-alert-mac/releases).
- **Alpha builds (opt-in).** Early, untested versions for people who want to try changes first. Turn them on with "Alpha builds…" at the bottom of General; Check for Updates then mentions a newer alpha, and it only installs if you choose it.
- **Runs in the background.** Alerts keep working even with the menu bar icon hidden. Turn them off with the switch in Settings.
- **Never asks for drive access.** Drive name, size and free space come from macOS's own drive list, so Disk Alert never looks inside your drives.

## Screenshots

| Light | Dark |
| --- | --- |
| ![Menu bar, light](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/menu-light.png) | ![Menu bar, dark](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/menu-dark.png) |
| ![General settings, light](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-general-light.png) | ![General settings, dark](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-general-dark.png) |
| ![Drives settings, light](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-drives-light.png) | ![Drives settings, dark](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-drives-dark.png) |
| ![Custom Sounds settings, light](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-sounds-light.png) | ![Custom Sounds settings, dark](https://raw.githubusercontent.com/open-luc/disk-alert-mac/screenshots/settings-sounds-dark.png) |

## Install

1. Download `Disk-Alert-x.y.z.dmg` from the [latest release](https://github.com/open-luc/disk-alert-mac/releases/latest).
2. Open it and drag **Disk Alert** into your Applications folder.
3. The app isn't signed with a paid Apple developer account, so the first time, Control-click it and choose **Open**, then **Open** again.
   If macOS still blocks it, run this once in Terminal:
   ```
   xattr -dr com.apple.quarantine "/Applications/Disk Alert.app"
   ```
4. Allow notifications when asked.

Requires macOS 15 or later; the Liquid Glass look appears on macOS 26 and later. Runs natively on Apple silicon and Intel.

## How it works

Disk Alert has two parts:

- **Disk Alert.app** is the menu bar icon and Settings window.
- **Disk Alert Agent**, inside the app, is a tiny background process that watches drives and posts the notifications. It's started by macOS's own `launchd` from `~/Library/LaunchAgents/app.diskalert.agent.plist`, uses almost no CPU while idle, and keeps running when the menu bar app is closed.

Settings, known drives and history are stored in `~/Library/Application Support/Disk Alert/`.

## Uninstall

Open Settings and click **Uninstall…**. It stops the agent, removes its settings, and moves the app to the Trash. Sounds you added stay in `~/Library/Sounds`.

## Build from source

On a Mac with Xcode or the Command Line Tools:

```
./scripts/build.sh
```

The app lands in `build/Disk Alert.app`, with an installer at `build/Disk-Alert-x.y.z.dmg`. Every push to `main` is built by GitHub Actions and published as a new release, with the patch number going up each time (major and minor come from the `VERSION` file).

## License

MIT. See [LICENSE](LICENSE).
