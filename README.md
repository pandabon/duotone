# Duotone

Set Light, Dark or System appearance for each Mac app separately.

## Features

- One-click Light, Dark or System per app, including sandboxed apps
- List and grid views, with filters and search
- Compact icon-only mode
- Type a name to jump to an app, as in Finder
- Import and export your settings
- System appearance switch

## Install

Requires macOS 26 or later on Apple silicon.

Download the DMG from [Releases](https://github.com/pandabon/duotone/releases) and drag Duotone to Applications. The app isn't notarized, so try to open it once, then choose **Open Anyway** in System Settings > Privacy & Security.

To build from source, you need Xcode:

```sh
git clone https://github.com/pandabon/duotone.git
cd duotone
scripts/build.sh --open
```

Run tests with `swift test`.

## How it works

Duotone sets each app's `NSRequiresAquaSystemAppearance` preference, the same as:

```sh
defaults write com.apple.dt.Xcode NSRequiresAquaSystemAppearance -bool true
```

`true` forces Light, `false` forces Dark, and no value follows the system. Sandboxed apps get the value in their container instead. Running apps restart to apply a change, and are never force-quit. Finder and the Dock are the exception: they are restarted, and macOS brings them straight back.

## Permissions

- **Media & Apple Music:** only when you change Music or TV. Duotone can't read their setting, so it shows the last value it set.
- **Full Disk Access:** only to change apps whose container macOS protects. The first launch may show a "Data Access Blocked" notice while Duotone finds them.
- **Automation:** only for the system appearance switch.

Duotone makes no network requests.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘S / ⌘O | Export / import settings |
| ⌘1 / ⌘2 | Grid / list view |
| ⌘3 | Compact mode |
| ⌘R | Refresh |
| ⌘, | Settings |

## Credits

A ground-up revamp inspired by [Gray](https://github.com/zenangst/Gray) by Christoffer Winterkvist. Built with [Claude](https://claude.com/claude-code).

## Licence

[MIT](LICENSE)
