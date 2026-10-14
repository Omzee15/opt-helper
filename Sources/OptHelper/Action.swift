import AppKit

/// The only things the launcher is allowed to do. There is deliberately no
/// "run command" or "run script" action: model output can only open things.
struct Action: Codable, Equatable {
    enum Kind: String, Codable {
        case openURL = "open_url"      // open a URL (optionally in a specific browser app)
        case openApp = "open_app"      // launch / focus an application
        case newWindow = "new_window"  // open a new window of an app (optionally at a URL)
        case openFolder = "open_folder" // open a folder under the projects root in an editor/Finder
        case runShortcut = "run_shortcut" // run an allowlisted terminal shortcut in a new Terminal window
    }
    var type: Kind
    var url: String?
    var app: String?
    var path: String?
    var profile: String?     // Safari profile name for open_url
    var shortcut: String?
    var ports: [Int]?
}

struct ModelReply: Codable {
    var actions: [Action]?
    var remember: [Remembered]?
    var say: String?

    struct Remembered: Codable {
        var phrase: String
        var note: String?
    }
}

enum Executor {
    /// Returns a human-readable summary, or throws if nothing could be opened.
    static func run(_ actions: [Action]) throws -> String {
        var done: [String] = []
        for a in actions.prefix(8) {
            switch a.type {
            case .openURL:
                let u = try validURL(a.url)
                let browser = (a.app?.isEmpty == false) ? a.app! : Settings.shared.browser
                if browser.lowercased() == "safari" {
                    let profile = (a.profile?.isEmpty == false) ? a.profile! : Settings.shared.safariProfile
                    if profile.isEmpty { try open(["-a", "Safari", u.absoluteString]) }
                    else { try openInSafariProfile(profile, u) }
                } else if browser == "System default" {
                    NSWorkspace.shared.open(u)
                } else {
                    try open(["-a", browser, u.absoluteString])
                }
                done.append(u.host ?? u.absoluteString)
            case .openApp:
                guard let app = a.app, !app.isEmpty else { throw LauncherError.bad("missing app") }
                try open(["-a", app])
                done.append(app)
            case .openFolder:
                guard let p = a.path, let dir = FolderSearch.resolve(p) else {
                    throw LauncherError.bad("No folder matching \"\(a.path ?? "")\" in \(ContextStore.projectsRoot.lastPathComponent)")
                }
                let app = (a.app?.isEmpty == false) ? a.app! : ContextStore.editor
                try open(["-a", app, dir.path])
                done.append(dir.lastPathComponent)
            case .runShortcut:
                done.append(try runShortcut(a))
            case .newWindow:
                guard let app = a.app, !app.isEmpty else { throw LauncherError.bad("missing app") }
                if let s = a.url, !s.isEmpty {
                    let u = try validURL(s)
                    if isChromium(app) {
                        try open(["-na", app, "--args", "--new-window", u.absoluteString])
                    } else {
                        try open(["-a", app, u.absoluteString])
                    }
                } else {
                    try open(isChromium(app) ? ["-na", app, "--args", "--new-window"] : ["-n", "-a", app])
                }
                done.append("new \(app) window")
            }
        }
        if done.isEmpty { throw LauncherError.bad("nothing to open") }
        return "Opened " + done.joined(separator: ", ")
    }

    /// Safari has no CLI for profiles, so use its File ▸ New Window ▸ "New <profile> Window" menu item,
    /// then point the new window at the URL. Needs Accessibility permission for this app (macOS asks once).
    private static func openInSafariProfile(_ profile: String, _ url: URL) throws {
        func osa(_ lines: [String], _ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = lines.flatMap { ["-e", $0] } + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                let m = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if m.contains("-1719") || m.contains("not allowed assistive") || m.contains("-25211") {
                    throw LauncherError.bad("Allow OptHelper in System Settings ▸ Privacy & Security ▸ Accessibility, then retry.")
                }
                throw LauncherError.bad("Safari: " + m.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let menuPath = "menu 1 of menu item \"New Window\" of menu \"File\" of menu bar 1"
        _ = try osa(["tell application \"Safari\" to activate"], [])
        Thread.sleep(forTimeInterval: 0.3)
        let names = try osa(["tell application \"System Events\" to tell process \"Safari\" to get name of every menu item of \(menuPath)"], [])
            .components(separatedBy: ", ")
        func clean(_ n: String) -> String {
            var t = n.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if t.hasPrefix("New ") { t.removeFirst(4) }
            if t.hasSuffix(" Window") { t.removeLast(7) }
            return t.lowercased()
        }
        guard let idx = names.firstIndex(where: { clean($0) == profile.lowercased() }) else {
            throw LauncherError.bad("No Safari profile named \"\(profile)\". Found: " + names.map(clean).joined(separator: ", "))
        }
        _ = try osa(["on run argv",
                     "tell application \"System Events\" to tell process \"Safari\" to click menu item (item 1 of argv as integer) of \(menuPath)",
                     "delay 0.6",
                     "tell application \"Safari\" to set URL of front document to (item 2 of argv)",
                     "end run"], [String(idx + 1), url.absoluteString])
    }

    /// Builds the command ONLY from the allowlisted shortcut in context.json plus integer ports,
    /// so model output can never inject arbitrary shell text.
    private static func runShortcut(_ a: Action) throws -> String {
        guard let name = a.shortcut?.lowercased(),
              let sc = ContextStore.load()?.terminal_shortcuts?.first(where: { $0.name.lowercased() == name }),
              let base = sc.command else {
            throw LauncherError.bad("No runnable shortcut named \"\(a.shortcut ?? "")\"")
        }
        let ports = a.ports ?? []
        guard ports.allSatisfy({ (1...65535).contains($0) }) else { throw LauncherError.bad("Invalid port") }
        var cmd = base
        if !ports.isEmpty {
            if sc.forward == true { cmd += " --forward " + ports.map(String.init).joined(separator: " ") }
            else if sc.port_args == true { cmd += " " + ports.map(String.init).joined(separator: " ") }
            else { throw LauncherError.bad("\(sc.name) doesn't take ports") }
        } else if sc.port_args == true {
            throw LauncherError.bad("\(sc.name) needs a port")
        }
        if let cwd = sc.cwd {
            guard let dir = FolderSearch.resolve(ContextStore.projectsRoot.appendingPathComponent(cwd).path) else {
                throw LauncherError.bad("Folder not found: \(cwd)")
            }
            cmd = "cd '\(dir.path)' && " + cmd
        }
        if sc.confirm == true {
            let alert = NSAlert()
            alert.messageText = "Run \"\(cmd)\" in Terminal?"
            alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { throw LauncherError.bad("Cancelled") }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to do script \"\(cmd)\"",
                       "-e", "tell application \"Terminal\" to activate"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LauncherError.bad("Terminal: " + msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return "ran \"\(cmd)\""
    }

    private static func validURL(_ s: String?) throws -> URL {
        guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else {
            throw LauncherError.bad("refused URL: \(s ?? "nil")")
        }
        return u
    }

    private static func isChromium(_ app: String) -> Bool {
        let a = app.lowercased()
        return ["chrome", "brave", "edge", "arc", "chromium", "vivaldi", "opera"].contains { a.contains($0) }
    }

    /// Always /usr/bin/open with an argument array: no shell involved.
    private static func open(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LauncherError.bad(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum LauncherError: LocalizedError {
    case bad(String), provider(String)
    var errorDescription: String? {
        switch self {
        case .bad(let s), .provider(let s): return s
        }
    }
}
