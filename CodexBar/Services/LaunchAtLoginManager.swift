//
//  LaunchAtLoginManager.swift
//  CodexBar
//

import Foundation
import ServiceManagement

/// Wrapper around SMAppService (macOS 13+). Keeps the toggle in sync with
/// the actual system registration state.
enum LaunchAtLoginManager {

    enum LaunchAtLoginError: LocalizedError {
        case registrationFailed(Error)
        case unregistrationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let error):
                return "Could not enable Launch at Login: \(error.localizedDescription)"
            case .unregistrationFailed(let error):
                return "Could not disable Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    /// The system's actual registration state — source of truth for the UI.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return true }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return true }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            // .requiresApproval surfaces when the user must confirm in
            // System Settings > General > Login Items.
            return false
        }
    }
}
