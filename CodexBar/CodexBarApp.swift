//
//  CodexBarApp.swift
//  CodexBar
//

import SwiftUI
import AppKit

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The settings window, declared the standard SwiftUI way: a `Window`
        // scene (single instance — repeated `openWindow` fronts the existing
        // window) hosting the `NavigationSplitView` in `SettingsView`. The
        // status item only has to *ask* for this window by id — it never
        // builds or owns one.
        //
        // `defaultLaunchBehavior(.suppressed)` keeps the window closed at
        // launch: this is a menu bar app, the window opens only on demand.
        Window(String(localized: "Settings"), id: SettingsMetrics.windowID) {
            SettingsView(model: appDelegate.model)
        }
        .defaultSize(width: SettingsMetrics.idealWidth,
                     height: SettingsMetrics.idealHeight)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// One model for the whole app: the status item reads it, the `Settings`
    /// scene writes to it.
    let model = AppModel()

    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no main window — the status bar item is the app.
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusItemController(model: model)
        statusController.install()

        // TEMP PROBE (verification only, delete after use): with the environment
        // variable set, automatically open the settings window 3 seconds after launch.
        if ProcessInfo.processInfo.environment["CODEXBAR_PROBE"] == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSLog("CODEXBAR-PROBE openSettings fired")
                self.statusController.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.shutDown()
    }

    /// SwiftUI's default is "terminate when the last window closes". For a
    /// menu bar app that is fatal: while the popover is up, its content window
    /// is the only visible window, so dismissing it quits the whole app (the
    /// SwiftUI runtime even pokes the popover's window with `-close`, logging
    /// "`-close` should not be called on windows that the application did not
    /// create or own"). Only the explicit Quit item may terminate us.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
