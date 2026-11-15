# Third-party notices

File Explorer (native) has **no third-party runtime dependencies**. It is written in Swift and uses only
Apple system frameworks that ship with macOS: SwiftUI, AppKit, QuickLookThumbnailing, Foundation and
UniformTypeIdentifiers.

The earlier Electron build bundled Electron, Chromium, Node.js, React and Zustand; none of them are part
of this version. The optional `analytics/` Cloudflare worker in this repository is a separate server-side
component and is not shipped inside the app.

The app icon sources in `build/` are part of this project and covered by the project LICENSE.
