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

1. Download the [latest DMG](https://github.com/pandabon/duotone/releases/latest).
2. Open it and drag Duotone to Applications.
3. Open Duotone. macOS blocks it the first time because it isn't notarized.
4. Go to System Settings > Privacy & Security and choose **Open Anyway**.

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
