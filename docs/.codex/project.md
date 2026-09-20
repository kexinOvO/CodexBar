# Project

CodexBar is a native macOS menu-bar SwiftUI/AppKit app. The Xcode project is `CodexBar.xcodeproj`, and the `CodexBar` scheme produces the app bundle.

Release packaging is handled by `scripts/create-dmg.sh`. A `v*` tag triggers `.github/workflows/release.yml`, which builds the app and publishes a standard drag-to-Applications DMG.
