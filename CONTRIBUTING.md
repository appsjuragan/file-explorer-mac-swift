# Contributing to File Explorer

Thanks for your interest in improving File Explorer — a native, tabbed file manager for macOS
written in Swift (SwiftUI + AppKit).

## Getting started

```bash
swift build          # debug build
swift run            # launch from the terminal
swift test           # unit tests
```

## Before opening a pull request

- `swift build -c release` and `swift test` must pass with no new warnings.
- Follow DRY / KISS / SOLID and keep names descriptive.
- Validate all external input (file names, archive entries, URLs); never build shell strings —
  use `ProcessRunner` with fixed executables.
- Do not log or transmit file names or paths (PII). The app has no telemetry; keep it that way.
- Add tests for behaviour changes; keep pure logic in `Core/` so it stays testable.
- Keep PRs focused; open an issue first for larger changes.

## Project layout

| Path | What |
| --- | --- |
| `Sources/FileExplorer/Core` | Pure models and helpers (sorting, paths, validation, formatting) |
| `Sources/FileExplorer/Services` | File system, cloud, process, icons, updates |
| `Sources/FileExplorer/State` | `ExplorerModel` (per-window state) |
| `Sources/FileExplorer/UI` | AppKit file lists and SwiftUI chrome |
| `Sources/FileExplorer/App` | App entry and menu commands |
| `Tests/FileExplorerTests` | XCTest suite |
| `analytics/` | Legacy, unused serverless worker (not called by the app) |

## Building a release

```bash
scripts/build-app.sh                      # universal, ad-hoc signed
SIGN_IDENTITY="Developer ID Application: …" NOTARIZE=1 scripts/build-app.sh
```

Copy `.env.signing.example` to `.env.signing` for notarization credentials.

By contributing, you agree that your contributions are licensed under the project's
[Apache-2.0 License](LICENSE).
