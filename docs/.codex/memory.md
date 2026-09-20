# Durable implementation notes

Last reviewed: 2026-09-20

- Do not make `AppSettings` decoding fail because one preference has an
  unknown enum, wrong JSON type, or missing value; that would cause
  `CacheStore` to treat the whole settings file as corrupt.
- Keep settings persistence in `AppModel` rather than adding separate view
  storage for user preferences. `@AppStorage` is reserved for view-only state
  such as the last selected settings pane.
- `LaunchAtLoginManager` is authoritative for the login-item toggle. Mirror
  its actual state into `AppSettings.launchAtLogin`; the JSON field is not a
  substitute for querying `SMAppService`.
- Regression coverage for persistence lives in
  `CodexBarTests/AppSettingsTests.swift` and
  `CodexBarTests/CacheStoreTests.swift`.
