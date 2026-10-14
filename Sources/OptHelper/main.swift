import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = LauncherPanel()
    private var hotKey: HotKey!
    private var hover: HoverTrigger!
    private let preferences = PreferencesWindow()
    private let permissions = PermissionsWindow()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "OptHelper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        panel.model.onSubmit = { [weak self] in self?.submit($0) }
        panel.model.onDismiss = { [weak self] in self?.panel.dismiss() }
        panel.model.onSearch = { [weak self] in self?.panel.present(.launcher) }
        panel.model.onOpenSettings = { [weak self] in self?.openPreferences() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // A hover-opened dashboard closes when the pointer leaves it, not on focus loss.
            guard let p = self?.panel, p.model.mode == .launcher || !p.model.openedByHover, !p.model.busy else { return }
            p.dismiss()
        }

        hotKey = HotKey { [weak self] in self?.toggle() }
        if !hotKey.register(settings.hotKey) { notifyHotKeyFailed() }
        preferences.recorder.apply = { [weak self] in self?.hotKey.register($0) ?? false }
        preferences.recorder.suspend = { [weak self] in self?.hotKey.unregister() }

        hover = HoverTrigger(panel: panel)
        hover.start()
        permissions.showIfFirstLaunch()
    }

    /// An accessory app has no menu bar, so ⌘V/⌘C/⌘A/⌘Z (and tools that paste, like Wispr Flow)
    /// would have no target. A hidden Edit menu restores the standard text shortcuts.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func toggle() {
        if panel.isVisible && panel.model.expanded && panel.model.mode == .launcher { panel.dismiss() } else { panel.present(.launcher) }
    }

    private func notifyHotKeyFailed() {
        statusItem.button?.toolTip = "Hotkey \(settings.hotKey.title) is taken by another app"
    }

    // MARK: Running a query

    private func submit(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let m = panel.model

        // Fast path: a phrase we already learned runs instantly, without a model call.
        if let hit = Memory.shared.exact(query), let actions = hit.actions {
            do {
                let msg = try Executor.run(actions)
                Memory.shared.upsert(phrase: hit.phrase, note: nil, actions: nil)
                finish(msg)
            } catch { fail(error) }
            return
        }

        m.busy = true
        m.isError = false
        m.status = "Thinking with \(settings.provider.title) (\(settings.model(for: settings.provider)))…"
        Task { @MainActor in
            defer { m.busy = false }
            do {
                let reply = try await LLM.ask(query: query)
                for r in reply.remember ?? [] { Memory.shared.upsert(phrase: r.phrase, note: r.note, actions: nil) }
                let actions = reply.actions ?? []
                if actions.isEmpty {
                    m.isError = true
                    m.status = reply.say ?? "Nothing to open."
                                return
                }
                let msg = try Executor.run(actions)
                // Learn what worked, but never cache a web-search fallback: it would
                // permanently shadow the real answer once better context exists.
                if !actions.contains(where: Self.isSearchFallback) {
                    Memory.shared.upsert(phrase: query, note: nil, actions: actions)
                }
                finish(reply.say ?? msg)
            } catch { fail(error) }
        }
    }

    private static func isSearchFallback(_ a: Action) -> Bool {
        guard let h = a.url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return ["google.", "bing.com", "duckduckgo.com", "search.yahoo.", "ecosia.org"].contains { h.contains($0) }
    }

    private func finish(_ msg: String) {
        panel.model.status = msg
        panel.dismiss()
    }

    private func fail(_ error: Error) {
        panel.model.isError = true
        panel.model.status = error.localizedDescription
        // Opening a browser/Terminal steals focus and would hide the panel, hiding the error too.
        panel.reveal()
        let log = Memory.shared.url.deletingLastPathComponent().appendingPathComponent("last-error.log")
        try? "\(Date()): \(error.localizedDescription)\n".write(to: log, atomically: true, encoding: .utf8)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open launcher (\(settings.hotKey.title))", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open notch dashboard", action: #selector(openDashboard), keyEquivalent: "").target = self
        let hoverItem = NSMenuItem(title: "Open notch on hover", action: #selector(toggleHover), keyEquivalent: "")
        hoverItem.target = self
        hoverItem.state = settings.hoverToOpen ? .on : .off
        menu.addItem(hoverItem)
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let providerMenu = NSMenu()
        for p in Provider.allCases {
            let i = NSMenuItem(title: p.title, action: #selector(pickProvider(_:)), keyEquivalent: "")
            i.representedObject = p.rawValue; i.target = self
            i.state = settings.provider == p ? .on : .off
            providerMenu.addItem(i)
        }
        let pItem = NSMenuItem(title: "Provider: \(settings.provider.title)", action: nil, keyEquivalent: "")
        pItem.submenu = providerMenu
        menu.addItem(pItem)

        let modelMenu = NSMenu()
        let current = settings.model(for: settings.provider)
        for m in settings.provider.models {
            let i = NSMenuItem(title: m, action: #selector(pickModel(_:)), keyEquivalent: "")
            i.representedObject = m; i.target = self
            i.state = current == m ? .on : .off
            modelMenu.addItem(i)
        }
        let mItem = NSMenuItem(title: "Model: \(current)", action: nil, keyEquivalent: "")
        mItem.submenu = modelMenu
        menu.addItem(mItem)

        if settings.provider == .gemini {
            let k = settings.geminiKey.isEmpty ? "Set Gemini API key…" : "Change Gemini API key…"
            menu.addItem(withTitle: k, action: #selector(setGeminiKey), keyEquivalent: "").target = self
        }

        let bMenu = NSMenu()
        for b in Settings.browsers {
            let i = NSMenuItem(title: b, action: #selector(pickBrowser(_:)), keyEquivalent: "")
            i.representedObject = b; i.target = self
            i.state = settings.browser == b ? .on : .off
            bMenu.addItem(i)
        }
        let bItem = NSMenuItem(title: "Browser: \(settings.browser)", action: nil, keyEquivalent: "")
        bItem.submenu = bMenu
        menu.addItem(bItem)
        if settings.browser == "Safari" {
            let t = settings.safariProfile.isEmpty ? "Safari profile…" : "Safari profile: \(settings.safariProfile)…"
            menu.addItem(withTitle: t, action: #selector(setSafariProfile), keyEquivalent: "").target = self
        }

        let hkMenu = NSMenu()
        for h in HotKeyChoice.all {
            let i = NSMenuItem(title: h.title + (h == .commandSpace ? " (disable Spotlight's first)" : ""),
                               action: #selector(pickHotKey(_:)), keyEquivalent: "")
            i.representedObject = h.title; i.target = self
            i.state = settings.hotKey == h ? .on : .off
            hkMenu.addItem(i)
        }
        hkMenu.addItem(.separator())
        let isCustom = !HotKeyChoice.all.contains(settings.hotKey)
        let custom = NSMenuItem(title: isCustom ? "Custom: \(settings.hotKey.title)…" : "Custom…", action: #selector(openPreferences), keyEquivalent: "")
        custom.target = self
        custom.state = isCustom ? .on : .off
        hkMenu.addItem(custom)
        let hItem = NSMenuItem(title: "Shortcut: \(settings.hotKey.title)", action: nil, keyEquivalent: "")
        hItem.submenu = hkMenu
        menu.addItem(hItem)

        menu.addItem(.separator())
        Memory.shared.load()  // pick up hand edits
        let entries = Memory.shared.entries.sorted { $0.uses > $1.uses }
        let memMenu = NSMenu()
        if entries.isEmpty {
            memMenu.addItem(withTitle: "Nothing learned yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for e in entries {
            let item = NSMenuItem(title: Self.clip(e.phrase, 48), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let info = NSMenuItem(title: Self.clip(e.summary.isEmpty ? "(no actions)" : e.summary, 70), action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(.separator())
            let del = NSMenuItem(title: "Delete", action: #selector(deleteMemory(_:)), keyEquivalent: "")
            del.representedObject = e.phrase; del.target = self
            sub.addItem(del)
            item.submenu = sub
            memMenu.addItem(item)
        }
        if !entries.isEmpty {
            memMenu.addItem(.separator())
            memMenu.addItem(withTitle: "Delete all…", action: #selector(deleteAllMemory), keyEquivalent: "").target = self
        }
        let memItem = NSMenuItem(title: "Memory (\(entries.count))", action: nil, keyEquivalent: "")
        memItem.submenu = memMenu
        menu.addItem(memItem)
        menu.addItem(withTitle: "Edit memory file…", action: #selector(editMemory), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openLauncher() { panel.present(.launcher) }

    @objc private func openDashboard() { panel.present(.dashboard) }

    @objc private func openPermissions() {
        panel.dismiss()
        permissions.show()
    }

    @objc private func toggleHover() { settings.hoverToOpen.toggle() }

    @objc private func openPreferences() {
        panel.dismiss()
        preferences.show()
    }

    @objc private func pickProvider(_ s: NSMenuItem) {
        if let p = Provider(rawValue: s.representedObject as? String ?? "") { settings.provider = p }
    }

    @objc private func pickModel(_ s: NSMenuItem) {
        if let m = s.representedObject as? String { settings.setModel(m, for: settings.provider) }
    }

    @objc private func pickHotKey(_ s: NSMenuItem) {
        guard let h = HotKeyChoice.all.first(where: { $0.title == s.representedObject as? String }) else { return }
        if hotKey.register(h) { settings.hotKey = h; preferences.recorder.title = h.title } else {
            _ = hotKey.register(settings.hotKey)
            let a = NSAlert()
            a.messageText = "\(h.title) is already in use"
            a.informativeText = "For ⌘ Space, turn off Spotlight's shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc private func pickBrowser(_ s: NSMenuItem) {
        if let b = s.representedObject as? String { settings.browser = b }
    }

    @objc private func setSafariProfile() {
        let a = NSAlert()
        a.messageText = "Default Safari profile"
        a.informativeText = "Links open in a new window of this profile (e.g. Work). Leave empty to use Safari's frontmost window."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = settings.safariProfile
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { settings.safariProfile = f.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    @objc private func setGeminiKey() {
        let a = NSAlert()
        a.messageText = "Gemini API key"
        a.informativeText = "Stored in this app's preferences on your Mac."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { settings.geminiKey = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    @objc private func deleteMemory(_ s: NSMenuItem) {
        if let p = s.representedObject as? String { Memory.shared.remove(phrase: p) }
    }

    @objc private func deleteAllMemory() {
        let a = NSAlert()
        a.messageText = "Delete all \(Memory.shared.entries.count) learned shortcuts?"
        a.informativeText = "Your GitHub, server and folder context is not affected."
        a.addButton(withTitle: "Delete all"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Memory.shared.removeAll() }
    }

    @objc private func editMemory() {
        Memory.shared.save()
        NSWorkspace.shared.open(Memory.shared.url)
    }

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        try? (s.status == .enabled ? s.unregister() : s.register())
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
