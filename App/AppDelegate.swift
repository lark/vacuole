// Copyright 2026 Wang Jian
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import Combine
import SwiftUI
import VacuoleShared

/// App entry point and menu bar shell.
///
/// Deliberately does **not** use SwiftUI's `MenuBarExtra`: on macOS 26 `MenuBarExtra` relies on
/// SwiftUI's FrontBoard scene (status item scene) to host the status bar item; in practice that
/// scene gets repeatedly rebuilt / cannot be inserted stably, leaving the icon invisible and hard
/// to diagnose. Instead we use AppKit's native `NSStatusItem` + `NSMenu`, which is directly
/// controllable. The settings window is likewise managed by AppKit; its content is still SwiftUI.
///
/// The entry point is in `main.swift` (top-level code).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// Allowed to be constructed from `main.swift`'s (non-isolated) top-level code.
    nonisolated override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupEditMenu()
        observeTunnelState()
        DaemonClient.shared.connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Tear the tunnel down on quit (menu quit, logout or shutdown). The daemon outlives the GUI, so
    /// leaving the tunnel up would keep the machine's routes and DNS captured with nobody able to stop
    /// it. Waiting synchronously here guarantees the daemon has finished before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DaemonClient.shared.tunnelState != .stopped {
            DaemonClient.shared.stopTunnelSync()
        }
        DaemonClient.shared.stopDNSSync()
        return .terminateNow
    }

    // MARK: - Main menu

    /// An accessory (menu-bar only) app shows no menu bar, and we never installed a main menu, so the
    /// standard editing shortcuts had no target at all: ⌘C/⌘V/⌘A/⌘Z did nothing in text fields while
    /// right-click still worked (that menu is built by AppKit's text view itself). Installing an Edit
    /// menu gives those key equivalents a responder-chain target; it is never displayed.
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: L("ui.menu.edit"))
        editMenu.addItem(withTitle: L("ui.menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        // An uppercase key equivalent means ⇧⌘Z
        editMenu.addItem(withTitle: L("ui.menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("ui.menu.cut"), action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("ui.menu.copy"), action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("ui.menu.paste"), action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("ui.menu.selectAll"), action: Selector(("selectAll:")), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Status bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(for: DaemonClient.shared.tunnelState)

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    private func observeTunnelState() {
        DaemonClient.shared.$tunnelState
            .sink { [weak self] state in
                self?.statusItem?.button?.image = Self.statusImage(for: state)
            }
            .store(in: &cancellables)
    }

    /// Tunnel state → menu bar icon. The symbol name must be a real SF Symbol.
    private static func statusImage(for state: TunnelState) -> NSImage? {
        let name: String
        switch state {
        case .running, .starting, .stopping:
            name = "shield.lefthalf.filled"
        case .error:
            name = "shield.slash"
        case .stopped:
            name = "shield"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "vacuole")
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: "vacuole")
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu building (rebuilt on each open from current state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let client = DaemonClient.shared

        // ── Daemon status ──
        menu.addItem(infoItem(client.connected ? L("ui.menu.daemonConnected") : L("ui.menu.daemonDisconnected")))
        if let version = client.daemonVersion {
            menu.addItem(infoItem(version))
        }
        if let error = client.lastError {
            // A menu item's title sets the menu width and daemon errors are unbounded, so only a
            // clipped preview goes into the title; the full text is reachable through the item's
            // tooltip and the detail alert. (macOS popovers/notifications would need the menu to
            // close first or an extra user authorization, so an alert is the cheaper surface.)
            let item = actionItem(L("ui.menu.errorFormat", Self.clipped(error)), #selector(showErrorDetails))
            item.toolTip = error
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // ── Tunnel control ──
        switch client.tunnelState {
        case .running:
            menu.addItem(actionItem(L("ui.tunnel.stop"), #selector(stopTunnel)))
            if let name = client.activeConfigName {
                menu.addItem(infoItem(L("ui.menu.currentConfigFormat", name)))
            }
        case .starting, .stopping:
            menu.addItem(infoItem(client.tunnelState == .starting ? L("ui.tunnel.startingEllipsis") : L("ui.tunnel.stoppingEllipsis")))
        case .stopped, .error:
            let startItem = actionItem(L("ui.tunnel.start"), nil)
            let submenu = NSMenu()
            if client.configs.isEmpty {
                submenu.addItem(infoItem(L("ui.menu.noConfigs")))
                startItem.isEnabled = false
            } else {
                for config in client.configs {
                    let item = actionItem(config.name, #selector(startTunnel(_:)))
                    item.representedObject = config.name
                    submenu.addItem(item)
                }
            }
            startItem.submenu = submenu
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // ── DNS status ──
        let dnsText: String
        if client.dnsRunning && client.dnsActivated {
            dnsText = L("ui.dns.runningActivated")
        } else if client.dnsRunning {
            dnsText = L("ui.status.running")
        } else {
            dnsText = L("ui.dns.stopped")
        }
        menu.addItem(infoItem(L("ui.menu.dnsFormat", dnsText)))

        // ── Domain sets ──
        if let activeID = client.activeSetID,
           let set = client.domainSets.first(where: { $0.id == activeID }) {
            menu.addItem(infoItem(L("ui.menu.domainSetFormat", set.name)))
        } else {
            menu.addItem(infoItem(L("ui.menu.domainSetInactive")))
        }
        if !client.domainSets.isEmpty {
            let switchItem = actionItem(L("ui.menu.switchDomainSet"), nil)
            let submenu = NSMenu()
            for set in client.domainSets {
                // A "✓ " prefix would shift this one title past the others; a trailing marker keeps
                // every title starting at the same x
                let title = set.id == client.activeSetID ? "\(set.name) ✓" : set.name
                let item = actionItem(title, #selector(activateDomainSet(_:)))
                item.representedObject = set.id.uuidString
                submenu.addItem(item)
            }
            switchItem.submenu = submenu
            menu.addItem(switchItem)
        }

        menu.addItem(.separator())

        menu.addItem(actionItem(L("ui.menu.openSettings"), #selector(openSettings), key: ","))
        menu.addItem(actionItem(L("ui.menu.reconnectDaemon"), #selector(reconnectDaemon)))

        menu.addItem(.separator())

        // ── Tools ──
        menu.addItem(actionItem(L("ui.menu.flushDNS"), #selector(flushDNSCache)))

        menu.addItem(.separator())

        menu.addItem(actionItem(L("ui.menu.quit"), #selector(quit), key: "q"))
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Clip text for use as a menu item title (the title drives the menu's width).
    private static func clipped(_ text: String, limit: Int = 40) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    // MARK: - Menu actions

    @objc private func startTunnel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DaemonClient.shared.startTunnel(configName: name)
    }

    @objc private func stopTunnel() {
        DaemonClient.shared.stopTunnel()
    }

    @objc private func activateDomainSet(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        DaemonClient.shared.activateDomainSet(id: id)
    }

    @objc private func reconnectDaemon() {
        DaemonClient.shared.connect()
    }

    /// Show the untruncated last error. `informativeText` is not selectable, so a button copies it.
    @objc private func showErrorDetails() {
        guard let error = DaemonClient.shared.lastError else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("ui.menu.errorDetailsTitle")
        alert.informativeText = error
        alert.addButton(withTitle: L("ui.action.ok"))
        alert.addButton(withTitle: L("ui.menu.errorCopy"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(error, forType: .string)
        }
    }

    /// Flush the resolver cache through the daemon (the commands need root).
    @objc private func flushDNSCache() {
        DaemonClient.shared.flushDNSCache()
    }

    @objc private func quit() {
        // The synchronous tunnel/DNS teardown happens in applicationShouldTerminate
        NSApp.terminate(nil)
    }

    // MARK: - Settings window (managed by AppKit; content is a SwiftUI view)

    @objc private func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsTabsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("ui.window.settingsTitle")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 600))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}