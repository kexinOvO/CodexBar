//
//  StatusItemController.swift
//  CodexBar
//

import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem + NSPopover pair and keeps the button title in sync
/// with the menu bar display mode and live data.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    let model = AppModel()

    private var cancellables: Set<AnyCancellable> = []

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                   accessibilityDescription: "CodexBar")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Left click opens the popover, right click (or ⌃-click) shows the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        // The hosting controller reports the SwiftUI view's fitting size
        // (width fixed by PopoverMetrics, height content-driven) and keeps
        // popover.contentSize in sync when data loads.
        let hosting = NSHostingController(rootView: PopoverRootView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // Keep the title in sync with data + settings.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTitle()
            }
            .store(in: &cancellables)

        model.onSettingsChanged = { [weak self] _ in
            self?.updateTitle()
        }

        NotificationCenter.default.addObserver(forName: .openCodexBarSettings,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openSettings()
            }
        }

        model.start()
        updateTitle()
    }

    func shutDown() {
        model.shutdown()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Actions

    /// Single entry point for both mouse buttons: the status item button now
    /// receives left *and* right mouse-up, so route explicitly instead of
    /// relying on the default `NSStatusItem` menu behaviour.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.popoverWillOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Right-click menu

    /// Attach the menu just long enough for AppKit to track it, then detach it
    /// again so a plain left click still toggles the popover.
    private func showContextMenu() {
        guard let item = statusItem, let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        item.menu = makeContextMenu()
        button.performClick(nil)
        item.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        // Enablement is decided here, not by AppKit's responder chain — this
        // app has no main menu, so nothing would validate the items otherwise.
        menu.autoenablesItems = false

        let refresh = NSMenuItem(title: String(localized: "Refresh now"),
                                 action: #selector(refreshNow(_:)),
                                 keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise",
                                accessibilityDescription: nil)
        refresh.isEnabled = !model.isRefreshingStatus && !model.isRefreshingUsage
        menu.addItem(refresh)

        let settings = NSMenuItem(title: String(localized: "Settings"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Quit CodexBar"),
                              action: #selector(quit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        return menu
    }

    @objc private func refreshNow(_ sender: Any?) {
        model.manualRefresh()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(model: model)))
            window.title = String(localized: "CodexBar Settings")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 560))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Title

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        switch model.settings.menuBarDisplayMode {
        case .iconOnly:
            button.title = ""
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                   accessibilityDescription: "CodexBar")
        case .weeklyPercent:
            button.image = NSImage(systemSymbolName: "circle.fill",
                                   accessibilityDescription: "CodexBar")
            if let pct = model.status?.weeklyRemainingPercent {
                button.title = " \(Int(pct.rounded()))%"
            } else {
                button.title = ""
            }
        case .fiveHourAndWeekly:
            button.image = nil
            var parts: [String] = []
            if let fiveHour = model.status?.fiveHourRemainingPercent {
                parts.append("\(Int(fiveHour.rounded()))%")
            }
            if let weekly = model.status?.weeklyRemainingPercent {
                parts.append("\(Int(weekly.rounded()))%")
            }
            button.title = parts.isEmpty ? "" : "◉ " + parts.joined(separator: " · ")
        }
        button.image?.isTemplate = true
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {}
}
