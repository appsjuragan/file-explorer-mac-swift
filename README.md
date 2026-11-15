# File Explorer for macOS (native)

A tabbed file manager for macOS that follows the layout, menus and shortcuts of the current Windows 11
File Explorer — written in **Swift / SwiftUI / AppKit** with no web runtime and no third-party packages.

## Features

- **Tabs** (⌘T new, ⌘W close), multiple windows, open folders from Finder / the Dock.
- **Windows 11 chrome**: command bar (New, Cut, Copy, Paste, Rename, Share, Delete, Sort, View, Details pane, See more),
  address bar with breadcrumbs and typed paths (⌘L), search-as-you-type (⌘F), navigation pane (Quick access,
  your own categories, This PC with drives and cloud storage), details pane, status bar.
- **Views**: Extra large / Large / Medium / Small icons, List, Details, Tiles; sorting and grouping.
- **Windows shortcuts**: Backspace or ⌥← = Back, ⌥→ = Forward, ⌥↑ = Up, F2 rename, F5 refresh, Del delete,
  Enter open, ⌥Enter properties, ⌘Z undo (rename, move, copy, delete), type-ahead selection.
- **Context menu** with the icon row (Cut, Copy, Paste, Rename, Delete), Open with, Compress / Extract, Share,
  Copy as path, Open in Terminal, pin to Quick access.
- **Drag & drop** between windows, tabs, Finder and the navigation pane (⌥ = copy; same volume = move).
- **Cloud awareness** for Dropbox, OneDrive, iCloud Drive, Google Drive and Box (open on the web, make available offline).
- Delete goes to the Trash and can be undone; replacing a file also goes through the Trash.

## Build

Requirements: macOS 13+, Xcode command line tools (Swift 5.9+).

```sh
swift build -c release          # binary only
swift test                      # unit tests
scripts/build-app.sh            # universal "File Explorer.app" + zip in dist/ (ad-hoc signed)
```

For a Developer-ID signed, notarized build copy `.env.signing.example` to `.env.signing`, then run
`SIGN_IDENTITY="Developer ID Application: …" NOTARIZE=1 scripts/build-app.sh`.

## Permissions

The app is not sandboxed (a file manager must reach arbitrary paths). macOS asks for access to Desktop,
Documents, Downloads and external volumes on first use. For system locations grant **Full Disk Access**
in System Settings › Privacy & Security; the app offers a shortcut when it hits a permission error.

## Privacy and security

- **No telemetry.** The app sends no analytics. Its only network request is an optional, notify-only
  check of the project's GitHub Releases page; set `FE_NO_UPDATES=1` to disable it.
- File names are validated before any rename or create; archives are pre-scanned and rejected if an entry
  would escape the destination (zip-slip); external tools are run with fixed paths, no shell and a minimal
  environment; symlinks are never followed during copy, search or size scans; only https URLs on known
  hosts are ever opened.
- Preferences (pinned folders, categories, recent items, view settings) are stored locally in
  `UserDefaults`. Recent items hold file paths, so clear them from Home › Recent if the Mac is shared.

See [MIGRATION.md](MIGRATION.md) for how this differs from the Electron version.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
