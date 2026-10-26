// AppDelegate — app lifecycle, window management, and the menu bar.
//
// Owns the set of ViewerWindows (one per workstation), builds the App / Workstation
// / Window menus, and tears every window down cleanly on quit.

import AppKit

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [ViewerWindow] = []
    private let store = WorkstationStore.shared
    private var settingsWC: SettingsWindowController?
    private var workstationMenu: NSMenu!
    private var newWindowMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        store.onChange = { [weak self] in self?.rebuildMenus() }
        if let ws = initialWorkstation() {
            openWindow(for: ws, cascadeFrom: nil)
        } else {
            // No workstation registered yet — open Settings so the user can add one
            // (name / host / SSH); a viewer window opens once they do.
            openSettings()
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit only after EVERY window's stream is gracefully torn down, so no box is
    /// left with an orphaned single-session slot.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !windows.isEmpty else { return .terminateNow }
        var replied = false
        func replyOnce() {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        let group = DispatchGroup()
        for vw in windows { group.enter(); vw.disconnectForQuit { group.leave() } }
        group.notify(queue: .main) { replyOnce() }
        // Safety valve: a wedged WKWebView must not make the app unquittable.
        // The clean-disconnect flush is 0.8s; 3s is ample before we bail out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !replied { NSLog("IsaacConnect: quit teardown timed out — terminating anyway") }
            replyOnce()
        }
        return .terminateLater
    }

    // MARK: window management
    /// The window the Workstation/Reconnect/Disconnect actions apply to: the key
    /// viewer window, else the most recently opened.
    private var frontViewer: ViewerWindow? {
        if let key = NSApp.keyWindow, let vw = windows.first(where: { $0.window === key }) { return vw }
        return windows.last
    }

    /// A box is "open" if some window already targets its endpoint (single-session =
    /// at most one window per host:port, regardless of which row was picked).
    private func windowShowing(_ w: Workstation) -> ViewerWindow? {
        windows.first { $0.workstation.endpoint == w.endpoint }
    }

    @discardableResult
    private func openWindow(for w: Workstation, cascadeFrom sibling: NSWindow?) -> ViewerWindow {
        let vw = ViewerWindow(workstation: w, appDelegate: self)
        windows.append(vw)
        vw.show(cascadeFrom: sibling)
        rebuildMenus()
        return vw
    }

    func windowDidClose(_ vw: ViewerWindow) {
        windows.removeAll { $0 === vw }
        rebuildMenus()
    }

    /// Honor ISAAC_IP (scripting): if it matches a saved host use that workstation,
    /// else view it as an ad-hoc target. Otherwise the first saved workstation, or
    /// nil when none are registered yet (→ open Settings to add one).
    private func initialWorkstation() -> Workstation? {
        if let ip = ProcessInfo.processInfo.environment["ISAAC_IP"] {
            return store.workstation(host: ip) ?? Workstation(name: ip, host: ip)
        }
        return store.workstations.first
    }

    // MARK: menus
    private func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Isaac Connect", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Isaac Connect", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Isaac Connect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let wsItem = NSMenuItem(); workstationMenu = NSMenu(title: "Workstation"); wsItem.submenu = workstationMenu
        workstationMenu.delegate = self   // rebuild on open so ✓ tracks the front window
        main.addItem(wsItem)

        let winItem = NSMenuItem(); let winMenu = NSMenu(title: "Window"); winItem.submenu = winMenu
        let newWinItem = NSMenuItem(title: "New Window for", action: nil, keyEquivalent: "")
        newWindowMenu = NSMenu(title: "New Window for")
        newWindowMenu.autoenablesItems = false   // we set enabled state explicitly (single-session)
        newWindowMenu.delegate = self            // rebuild on open so open-boxes are grayed live
        newWinItem.submenu = newWindowMenu
        winMenu.addItem(newWinItem)
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(winItem)
        NSApp.windowsMenu = winMenu   // AppKit appends the open-window list

        NSApp.mainMenu = main
        rebuildMenus()
    }

    private func rebuildMenus() {
        rebuildWorkstationMenu()
        rebuildNewWindowMenu()
    }

    // Rebuild each dynamic menu right before it opens, so checkmarks + grayed-out
    // (single-session) state always reflect the live window set.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === workstationMenu { rebuildWorkstationMenu() }
        else if menu === newWindowMenu { rebuildNewWindowMenu() }
    }

    private func rebuildWorkstationMenu() {
        guard let menu = workstationMenu else { return }
        menu.removeAllItems()
        let currentID = frontViewer?.workstation.id
        for w in store.workstations {
            let item = NSMenuItem(title: w.name, action: #selector(selectWorkstation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = w.id.uuidString
            item.state = (w.id == currentID) ? .on : .off
            if let shown = windowShowing(w), shown !== frontViewer {
                item.toolTip = "Already open in another window — selecting focuses it"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Cold-path actions: drive isaac-ctl on the box over SSH (needs the
        // workstation's ssh field). The viewer's reconnect loop picks the stream
        // up on its own once the sim is live — launch doesn't block on readiness.
        let front = frontViewer
        let hasSSH = !(front?.workstation.ssh.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        let profiles = front?.workstation.launchProfiles ?? []
        if profiles.isEmpty {
            // Just the built-in Isaac Sim launch — a single item (⇧⌘L).
            let launch = NSMenuItem(title: "Launch", action: hasSSH ? #selector(launchFront) : nil, keyEquivalent: "L")
            launch.target = self
            launch.toolTip = hasSSH ? nil : "Set the workstation's SSH (user@host) in Settings first"
            menu.addItem(launch)
        } else {
            // Custom profiles exist → "Launch ▸" submenu: the built-in Isaac Sim
            // default first, then each custom command. ⇧⌘L still fires the default.
            let launchItem = NSMenuItem(title: "Launch", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Launch")
            sub.autoenablesItems = false
            let def = NSMenuItem(title: "Isaac Sim", action: hasSSH ? #selector(launchFront) : nil, keyEquivalent: "L")
            def.target = self
            def.isEnabled = hasSSH
            sub.addItem(def)
            sub.addItem(.separator())
            for p in profiles {
                let it = NSMenuItem(title: p.name.isEmpty ? "(unnamed)" : p.name,
                                    action: hasSSH ? #selector(launchProfile(_:)) : nil, keyEquivalent: "")
                it.target = self
                it.representedObject = p.id.uuidString
                it.isEnabled = hasSSH
                it.toolTip = p.command
                sub.addItem(it)
            }
            launchItem.submenu = sub
            menu.addItem(launchItem)
        }
        let stop = NSMenuItem(title: "Stop", action: hasSSH ? #selector(stopFront) : nil, keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnectFront), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)
        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnectFront), keyEquivalent: "")
        disconnect.target = self
        menu.addItem(disconnect)
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Workstations…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    private func rebuildNewWindowMenu() {
        guard let menu = newWindowMenu else { return }
        menu.removeAllItems()
        for w in store.workstations {
            let item = NSMenuItem(title: w.name, action: #selector(newWindowFor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = w.id.uuidString
            item.isEnabled = (windowShowing(w) == nil)   // single-session: endpoint not already open
            menu.addItem(item)
        }
    }

    // MARK: actions
    @objc private func selectWorkstation(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let w = store.workstation(id: id),
              let front = frontViewer else { return }
        // This endpoint already shown in another window? Focus it rather than fight
        // for the single session slot.
        if let other = windowShowing(w), other !== front {
            other.window.makeKeyAndOrderFront(nil)
            return
        }
        front.controller.retarget(to: w)
        rebuildMenus()
    }

    @objc private func newWindowFor(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let w = store.workstation(id: id) else { return }
        if let existing = windowShowing(w) { existing.window.makeKeyAndOrderFront(nil); return }
        openWindow(for: w, cascadeFrom: frontViewer?.window)
    }

    @objc private func reconnectFront() { frontViewer?.controller.reconnect() }
    @objc private func disconnectFront() { frontViewer?.controller.disconnect() }

    /// Launch the sim on the front window's box (isaac-ctl over SSH). Returns
    /// as soon as the process is spawned; the viewer's reconnect loop latches onto
    /// the stream the moment :49100 goes live — that IS the readiness feedback.
    @objc private func launchFront() {
        guard let front = frontViewer else { return }
        let w = front.workstation
        RemoteLauncher.run(verb: "launch", on: w) { [weak self, weak front] result in
            NSLog("IsaacConnect: launch \(w.name) → \(result.output)")
            if result.ok {
                // Kick the window out of user-paused/idle so it starts trying.
                front?.controller.reconnect()
            } else {
                self?.showRemoteError(title: "Launch on \(w.name) failed", detail: result.output)
            }
        }
    }

    /// Launch a custom profile on the front box: `isaac-ctl run <base64(command)>`.
    /// Base64 dodges every ssh→sh quoting hazard in the user's command line. Like
    /// the default launch, the viewer's reconnect loop supplies readiness feedback.
    @objc private func launchProfile(_ sender: NSMenuItem) {
        guard let front = frontViewer,
              let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let profile = front.workstation.launchProfiles.first(where: { $0.id == id }) else { return }
        let cmd = profile.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            showRemoteError(title: "Profile “\(profile.name)” has no command", detail: "Add a command in Settings ▸ Launch Profiles.")
            return
        }
        let b64 = Data(cmd.utf8).base64EncodedString()
        let w = front.workstation
        RemoteLauncher.run(verb: "run \(b64)", on: w) { [weak self, weak front] result in
            NSLog("IsaacConnect: run '\(profile.name)' on \(w.name) → \(result.output)")
            if result.ok {
                front?.controller.reconnect()
            } else {
                self?.showRemoteError(title: "Launch “\(profile.name)” on \(w.name) failed", detail: result.output)
            }
        }
    }

    /// Stop Isaac Sim on the front window's box. Clean-disconnect our stream FIRST
    /// (frees the slot gracefully while the server is still alive), then ctl stop.
    @objc private func stopFront() {
        guard let front = frontViewer else { return }
        let w = front.workstation
        front.controller.disconnect { [weak self] in
            RemoteLauncher.run(verb: "stop", on: w) { result in
                NSLog("IsaacConnect: stop \(w.name) → \(result.output)")
                if !result.ok {
                    self?.showRemoteError(title: "Stop on \(w.name) failed", detail: result.output)
                }
            }
        }
    }

    private func showRemoteError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func openSettings() {
        if settingsWC == nil {
            let wc = SettingsWindowController()
            wc.onClose = { [weak self] in
                guard let self = self else { return }
                self.settingsWC = nil
                self.rebuildMenus()
                // First run: once a workstation is registered, open a viewer for it.
                if self.windows.isEmpty, let ws = self.store.workstations.first {
                    self.openWindow(for: ws, cascadeFrom: nil)
                }
            }
            settingsWC = wc
        }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
