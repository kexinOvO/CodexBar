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
        // No Dock icon, no main window — the status bar item is the app.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusItemController()
        statusController.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.shutDown()
    }
}
