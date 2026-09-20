//
//  SettingsView.swift
//  CodexBar
//
//  The settings *window* is a SwiftUI `Window` scene (see `CodexBarApp`);
//  this file is only its content. The root is a `NavigationSplitView`:
//  the sidebar lists the three panes, the detail area renders the matching
//  pane as a grouped `Form`. This is the standard modern macOS preferences
//  layout — sidebar material running to the top, traffic lights over the
//  sidebar, sidebar toggle, and the current pane's name as the leading
//  toolbar title above the content.
//
//  Nothing here draws its own window chrome, background, border, shadow or
//  switch. Each pane body is a plain `Form` + `Section` page built from stock
//  `Toggle` / `Picker` / `Slider` / `TextField` / `LabeledContent`.
//

import SwiftUI

// MARK: - Panes

/// Entries of the settings sidebar. Exactly three, by design: categories are
/// split by topic (behaviour / presentation / which codex we talk to), not by
/// individual setting.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appearance
    case cli

    var id: String { rawValue }

    /// Pane shown when the settings window first opens.
    static let initial: SettingsPane = .general

    /// Sidebar row label. `String(localized:)` rather than a bare literal so
    /// the same value also drives the window title.
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .appearance: return String(localized: "Appearance")
        case .cli: return String(localized: "CLI")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .cli: return "terminal"
        }
    }
}

/// Geometry + identity of the settings window, shared by the view, the
/// `Window` scene and the AppKit-side openers so the three can't drift apart.
enum SettingsMetrics {
    /// `Window` scene id — the one handle every opener uses.
    static let windowID = "settings"

    static let minWidth: CGFloat = 620
    static let minHeight: CGFloat = 420
    static let idealWidth: CGFloat = 700
    static let idealHeight: CGFloat = 560
}

// MARK: - Settings content

/// Sidebar on the left (`List(selection:)`), one pane on the right.
///
/// | Pane | Sections |
/// | --- | --- |
/// | General | Startup / Refresh / Notifications |
/// | Appearance | Appearance / Theme Color / Menu Bar / Quota / Popover / Heatmap |
/// | CLI | Codex path / Diagnostics |
struct SettingsView: View {
    @ObservedObject var model: AppModel

    /// The one piece of *view* state worth persisting, and the spec's
    /// `@AppStorage` bucket: which pane was open last. Preferences themselves
    /// stay in `AppSettings` (settings.json) so their side effects — timers,
    /// app appearance, notification arming — keep firing from a single place.
    @AppStorage("Settings.selectedPane") private var selectedPaneID = SettingsPane.initial.rawValue

    @State private var codexPathField: String = ""
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled
    @State private var launchAtLoginError: String?
    @State private var isDetecting = false
    /// Red validation message shown under the path field.
    @State private var cliPathMessage: String?
    /// The executable actually launched, when it differs from what's in the
    /// field (npm wrapper → native binary).
    @State private var resolvedPath: String?

    private let refreshIntervals: [(String, TimeInterval)] = [
        (String(localized: "1 min"), 60),
        (String(localized: "5 min"), 300),
        (String(localized: "10 min"), 600),
        (String(localized: "15 min"), 900),
        (String(localized: "30 min"), 1_800),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 240)
        } detail: {
            Form {
                switch selectedPane {
                case .general: generalPage
                case .appearance: appearancePage
                case .cli: cliPage
                }
            }
            .formStyle(.grouped)
            // Drives the leading toolbar title (the pane name above the
            // content) and the window title in one go.
            .navigationTitle(Text(verbatim: selectedPane.title))
        }
        .frame(minWidth: SettingsMetrics.minWidth,
               minHeight: SettingsMetrics.minHeight)
        .onAppear {
            syncLaunchAtLogin()
            // Never block the window on discovery: the scan can shell out to
            // the login shell, so it runs off-main and fills the field in.
            let persisted = model.settings.codexPathOverride ?? ""
            codexPathField = persisted
            guard persisted.isEmpty else { return }
            Task {
                let found = await Task.detached(priority: .userInitiated) {
                    CodexLocator.locate(override: nil)
                }.value
                if codexPathField.isEmpty, let found {
                    codexPathField = found.sourcePath
                    resolvedPath = found.path
                }
            }
        }
    }

    // MARK: - Navigation

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneID) ?? .initial
    }

    /// `List(selection:)` writes the tagged value; `@AppStorage` holds the
    /// raw value so the last-open pane survives relaunch. The default lives
    /// in one place: ``SettingsPane/initial``.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: selectedPaneID) ?? .initial },
                set: { selectedPaneID = ($0 ?? .initial).rawValue })
    }

    // MARK: - Pages

    /// App behavior that isn't about presentation: whether the app launches
    /// itself, how often it goes back for data, and which thresholds raise
    /// alerts. All are "how the app behaves while you're not looking at it",
    /// so they share one page.
    @ViewBuilder private var generalPage: some View {
        Section("Startup") {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    toggleLaunchAtLogin(newValue)
                }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        Section("Refresh") {
            Picker("Status refresh interval", selection: intervalBinding(\.statusRefreshInterval)) {
                ForEach(refreshIntervals, id: \.1) { Text($0.0).tag($0.1) }
            }
            Picker("Activity refresh interval", selection: intervalBinding(\.usageRefreshInterval)) {
                ForEach(refreshIntervals, id: \.1) { Text($0.0).tag($0.1) }
            }
        }

        Section("Notifications") {
            Toggle("Weekly below 10%", isOn: settingBinding(\.notifyWeeklyBelow10))
            Toggle("Weekly below 5%", isOn: settingBinding(\.notifyWeeklyBelow5))
            Toggle("5h below 10%", isOn: settingBinding(\.notifyFiveHourBelow10))
        }
    }

    /// Everything that decides what the app puts on screen: the color scheme,
    /// plus the menu bar, quota readout and heatmap — one topic: presentation.
    @ViewBuilder private var appearancePage: some View {
        // Headerless, mirroring System Settings › Appearance, where the pane
        // title is the label: repeating "Appearance" as a row label under a page
        // that is already titled Appearance just echoes the title bar.
        Section {
            Picker("Appearance", selection: settingBinding(\.appearance)) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Appearance"))
        }

        Section("Theme Color") {
            // Menu-style dropdown: Default keeps every historical color;
            // Custom reveals the color wheel below.
            Picker("Mode", selection: settingBinding(\.themeColorMode)) {
                ForEach(ThemeColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: model.settings.themeColorMode) { _, mode in
                // First switch to Custom: seed the wheel with a concrete
                // color so the persisted setting is explicit from the start.
                if mode == .custom, model.settings.themeColorHex == nil {
                    model.settings.themeColorHex = Self.seedThemeHex
                }
            }
            if model.settings.themeColorMode == .custom {
                LabeledContent("Color") {
                    ColorPicker("", selection: customColorBinding)
                        .labelsHidden()
                }
                Text("Brightness distinguishes usage states and activity levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Menu Bar") {
            Picker("Display", selection: settingBinding(\.menuBarDisplayMode)) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }

        Section("Quota") {
            Picker("Display mode", selection: settingBinding(\.quotaDisplayMode)) {
                ForEach(QuotaDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Simple hides when each quota resets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Popover") {
            LabeledContent("Width") {
                HStack(spacing: 10) {
                    Slider(value: popoverWidthBinding,
                           in: AppSettings.popoverWidthRange,
                           step: 10)
                    Text(popoverWidthLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Width of the popover panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Heatmap") {
            Toggle("Usage stats", isOn: settingBinding(\.showUsageStats))
            Text("Lifetime, peak, streak and longest-task summary below the heatmap.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Label on the left, control on the right — `LabeledContent` is
            // the system's own answer to "label + custom value", so the row
            // lines up with every `Picker` above it for free.
            LabeledContent("Range") {
                HStack(spacing: 10) {
                    Slider(value: heatmapMonthsBinding,
                           in: AppSettings.heatmapMonthRange,
                           step: 1)
                    Text(monthsLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Months of token activity to show in the heatmap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cliPage: some View {
        Section {
            LabeledContent("Codex path") {
                HStack(spacing: 8) {
                    TextField("Codex path", text: $codexPathField)
                        .labelsHidden()
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { commitTypedPath() }
                    // `String(localized:)` rather than a bare literal: a ternary
                    // of two literals would bind to the verbatim String
                    // overload and skip the string catalog.
                    Button(isDetecting
                           ? String(localized: "Checking…")
                           : String(localized: "Detect")) { detect() }
                        .disabled(isDetecting)
                }
            }
            if let resolvedPath, resolvedPath != codexPathField {
                LabeledContent("Resolved executable") {
                    Text(verbatim: resolvedPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            if let cliPathMessage {
                Text(cliPathMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.cliState == .notFound {
                Text("Codex CLI not found. Install Codex CLI and sign in with: codex login")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Diagnostics") {
            LabeledContent("Codex version", value: model.codexVersion ?? "—")
            LabeledContent("Last successful query",
                           value: TokenFormatter.relative(from: model.status?.fetchedAt))
            LabeledContent("Connection state", value: connectionStateText)
        }
    }

    private var connectionStateText: String {
        switch model.cliState {
        case .unknown: return String(localized: "Unknown")
        case .checking: return String(localized: "Checking…")
        case .ready: return String(localized: "Connected")
        case .notFound: return String(localized: "Codex CLI not found")
        case .notSignedIn: return String(localized: "Not signed in")
        case .failing(let detail): return String(localized: "Failing: \(detail)")
        }
    }

    // MARK: - CLI path

    /// The "Detect" button. With a non-empty field, validate exactly what the
    /// user typed — quietly falling back to a *different* install is how a typo
    /// turns into "it works but shows a path I didn't type". With an empty
    /// field, scan the machine.
    private func detect() {
        if CodexLocator.normalized(codexPathField) != nil {
            commitTypedPath()
        } else {
            autoDetect()
        }
    }

    /// Return in the field: validate the typed path, persist it, and never
    /// clear it on failure.
    private func commitTypedPath() {
        guard let typed = CodexLocator.normalized(codexPathField) else {
            model.settings.codexPathOverride = nil
            cliPathMessage = nil
            resolvedPath = nil
            model.recheckCLI()
            return
        }
        isDetecting = true
        cliPathMessage = nil
        Task {
            let located = await Task.detached(priority: .userInitiated) {
                CodexLocator.inspect(path: typed)
            }.value
            isDetecting = false
            guard let located else {
                cliPathMessage = String(localized: "No runnable Codex CLI at that path.")
                return
            }
            apply(located)
        }
    }

    private func autoDetect() {
        isDetecting = true
        cliPathMessage = nil
        Task {
            let located = await Task.detached(priority: .userInitiated) {
                CodexLocator.locate(override: nil)
            }.value
            isDetecting = false
            guard let located else {
                cliPathMessage = String(localized: "No Codex CLI found on this Mac.")
                model.recheckCLI()
                return
            }
            apply(located)
        }
    }

    private func apply(_ located: CodexLocator.LocatedCodex) {
        codexPathField = located.sourcePath
        resolvedPath = located.path
        model.settings.codexPathOverride = located.sourcePath
        cliPathMessage = nil
        model.recheckCLI()
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        let ok = LaunchAtLoginManager.setEnabled(enabled)
        syncLaunchAtLogin() // the system registration is the source of truth
        launchAtLoginError = ok ? nil : (enabled
            ? String(localized: "Registration failed. Approve CodexBar in System Settings › General › Login Items.")
            : String(localized: "Unregistration failed. Check System Settings › General › Login Items."))
    }

    /// Keep the legacy JSON field aligned with the actual SMAppService state.
    /// The system registration remains authoritative, but mirroring it into
    /// AppSettings means this setting follows the same persistence path as the
    /// rest of the preferences and can never be left stale by the view state.
    private func syncLaunchAtLogin() {
        let actual = LaunchAtLoginManager.isEnabled
        launchAtLogin = actual
        if model.settings.launchAtLogin != actual {
            model.settings.launchAtLogin = actual
        }
    }

    // MARK: - Bindings

    private func settingBinding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>)
        -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 })
    }

    private func intervalBinding(_ keyPath: WritableKeyPath<AppSettings, TimeInterval>)
        -> Binding<TimeInterval> {
        Binding(
            get: {
                let value = model.settings[keyPath: keyPath]
                return refreshIntervals.min(by: { abs($0.1 - value) < abs($1.1 - value) })?.1 ?? value
            },
            set: { model.settings[keyPath: keyPath] = $0 })
    }

    /// Slider works in `Double`; the model stores whole months.
    private var heatmapMonthsBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.heatmapMonthsClamped) },
            set: { model.settings.heatmapMonths = Int($0.rounded()) })
    }

    /// Slider is stepped by 10 pt; keep the persisted value on the grid too.
    private var popoverWidthBinding: Binding<Double> {
        Binding(
            get: { model.settings.popoverWidthClamped },
            set: { model.settings.popoverWidth = ($0 / 10).rounded() * 10 })
    }

    /// Localized "N pt" readout for the current slider value.
    private var popoverWidthLabel: String {
        let width = Int(model.settings.popoverWidthClamped)
        return String(localized: "\(width) pt")
    }

    /// Starting point offered the first time Custom is selected.
    private static let seedThemeHex = "#0A84FF"

    /// ColorPicker writes through to the persisted hex; the get side falls
    /// back to the seed color so a not-yet-seeded state still renders a wheel.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                model.settings.themeColorHex.flatMap(ThemeColor.color(fromHex:))
                    ?? ThemeColor.color(fromHex: Self.seedThemeHex)!
            },
            set: { model.settings.themeColorHex = ThemeColor.hex(from: $0) })
    }

    /// Localized "N months" readout for the current slider value.
    private var monthsLabel: String {
        let months = model.settings.heatmapMonthsClamped
        return String(localized: "\(months) months")
    }
}
