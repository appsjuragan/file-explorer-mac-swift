# Migration notes: Electron/TypeScript → native Swift

## Why

The Electron build shipped a full Chromium and Node.js per app (hundreds of MB on disk, several processes,
100+ MB of idle RAM). The native build is one small process that uses system frameworks already in memory.

| Concern | Electron | Native |
|---|---|---|
| Runtime | Chromium + Node (bundled) | System SwiftUI/AppKit |
| Processes | main + renderer + GPU + utility | 1 |
| File lists | React DOM, virtualised | `NSTableView` / `NSCollectionView` (cell recycling) |
| Icons / thumbnails | image bytes over IPC | `NSWorkspace` icons + QuickLook thumbnails, `NSCache` (48 MB cap) |
| Copy | JS stream/copy | `FileManager` (APFS clonefile, instant copies) |
| Disk work | main process | `Task.detached`, UI thread never blocks |
| Entitlements | JIT + unsigned memory | none (hardened runtime, no exceptions) |

## Feature mapping

Everything from v1.2.0 (tabs, Home, categories, pins, recent, cloud awareness, search, properties, compress /
extract, conflict dialog, undo) has a native equivalent. The UI was additionally reworked to match the
current Windows 11 File Explorer (command bar, breadcrumb address bar, details pane, shortcuts, icon-row
context menu). "26H2" was interpreted as the current Windows 11 Explorer.

## Intentional changes

- **Analytics removed.** The old build pinged a server with data including device-management status.
  The native build has no telemetry. The `analytics/` Cloudflare worker is untouched in case you re-add an
  explicit opt-in later.
- **Updater is notify-only.** It checks GitHub Releases and opens the release page; it never downloads or runs
  code. For silent updates adopt Sparkle (EdDSA-signed appcast).
- **Preferences are not imported.** Electron kept them in Chromium localStorage; users start with defaults.
- **Replace uses the Trash** so overwritten files are recoverable.

## Known gaps / limitations

- **Not compiled or tested in the environment that produced this code** (no Swift toolchain was available).
  Expect a few compile fixes on first build (AppKit drag-and-drop signatures, Sendable warnings). Run
  `swift build` and `swift test` first.
- Not implemented: breadcrumb sibling drop-downs, Quick Look on Space, live folder watching (use F5),
  thumbnails for types other than image / video / PDF.
- The `.app` is not sandboxed by design; see README › Permissions.
