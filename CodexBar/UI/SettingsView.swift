//
//  SettingsView.swift
//  CodexBar
//

import SwiftUI

/// Settings window. Sections: General / Refresh / Menu Bar / Notifications /
/// Appearance / CLI.
struct SettingsView: View {
    @ObservedObject var model: AppModel

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
        Form {
            Section("General") {
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

            Section("Menu Bar") {
                Picker("Display", selection: modeBinding) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Weekly below 10%", isOn: settingBinding(\.notifyWeeklyBelow10))
                Toggle("Weekly below 5%", isOn: settingBinding(\.notifyWeeklyBelow5))
                Toggle("5h below 10%", isOn: settingBinding(\.notifyFiveHourBelow10))
            }

            Section("Appearance") {
                Picker("Appearance", selection: settingBinding(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Heatmap") {
                HStack(spacing: 8) {
                    Text("Range")
                    Spacer(minLength: 8)
                    Text(monthsLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: heatmapMonthsBinding,
                       in: AppSettings.heatmapMonthRange,
                       step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(verbatim: "6")
                } maximumValueLabel: {
                    Text(verbatim: "10")
                }
                .labelsHidden()
                .accessibilityLabel(Text("Range"))
                Text("Months of token activity to show in the heatmap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CLI") {
                HStack {
                    TextField("Codex path", text: $codexPathField)
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
                LabeledContent("Codex version", value: model.codexVersion ?? "—")
                LabeledContent("Last successful query",
                               value: TokenFormatter.relative(from: model.status?.fetchedAt))
                LabeledContent("Connection state", value: connectionStateText)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
        .onAppear {
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
        launchAtLogin = LaunchAtLoginManager.isEnabled // resync with reality
        launchAtLoginError = ok ? nil : (enabled
            ? String(localized: "Registration failed. Approve CodexBar in System Settings › General › Login Items.")
            : String(localized: "Unregistration failed. Check System Settings › General › Login Items."))
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

    private var modeBinding: Binding<MenuBarDisplayMode> {
        settingBinding(\.menuBarDisplayMode)
    }

    /// Slider works in `Double`; the model stores whole months.
    private var heatmapMonthsBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.heatmapMonthsClamped) },
            set: { model.settings.heatmapMonths = Int($0.rounded()) })
    }

    /// Localized "N months" readout for the current slider value.
    private var monthsLabel: String {
        let months = model.settings.heatmapMonthsClamped
        return String(localized: "\(months) months")
    }
}
