# Architecture

Last reviewed: 2026-09-20

CodexBar is a macOS menu-bar SwiftUI/AppKit app. `AppDelegate` owns one
`AppModel`; `StatusItemController` and `SettingsView` share that model.

`AppModel.settings` is the single in-memory source for user preferences.
`CacheStore` persists it as `~/Library/Application Support/CodexBar/settings.json`
using atomic writes. The model loads settings before starting refresh tasks,
then rewrites the decoded value so legacy or repaired fields are normalized.

`AppSettings` uses independent per-key decoding. Missing or malformed fields
fall back to that field's default, while valid sibling fields survive. The
launch-at-login switch additionally mirrors the authoritative
`SMAppService.mainApp.status` value into the model when the settings page is
shown or changed.
