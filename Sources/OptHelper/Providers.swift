import Foundation

enum Prompt {
    static let system = """
    You are the brain of a macOS launcher (like Spotlight, but smart). The user types a short, informal, \
    possibly misspelled phrase. Work out what they want to open and answer with ONLY one JSON object, no prose, no code fences:

    {"actions":[{"type":"open_url","url":"https://...","app":"optional browser app name"}],
     "remember":[{"phrase":"short alias","note":"what it means"}],
     "say":"very short status line"}

    Allowed action types (nothing else exists, never invent others):
    - open_url: url must be http(s). Omit "app" unless the user names a browser (the app uses their configured browser). \
    Optional "profile" = Safari profile name, only if the user asks for one (see Safari profiles in context).
    - open_app: "app" = application name, e.g. "Visual Studio Code", "Terminal".
    - new_window: "app" = application name, optional "url".
    - open_folder: "path" = a folder name or path from the project folders list, optional "app" (default: the editor). \
    Only folders under the projects root can be opened.
    - run_shortcut: "shortcut" = name of a terminal shortcut that is NOT marked no-run, optional "ports" = integer array. \
    Opens a new Terminal window running it, one action per window ("connect to voxy and forward gpu2 12345" = \
    two actions: voxy with no ports, gpu2 with ports [12345]). Ports go only to shortcuts that forward or take ports.
    You can ONLY open tabs, applications, windows, folders, and run the allowlisted terminal shortcuts above. \
    Never write raw commands or scripts; never delete or modify anything. \
    If the request needs that, return no actions and explain in "say".

    Use the user's saved memory below to resolve nicknames, repos, servers and projects (it is ground truth). \
    If you must guess a URL (e.g. a GitHub repo's pull requests page is https://github.com/<owner>/<repo>/pulls), \
    prefer memory and the GitHub org context (repo names may be informal: "vox kg" = vox-kg-service or vox-kg-worker; pick the best match, \
    "dockopes" = dockerops); otherwise fall back to a web search URL rather than inventing an unlikely domain. \
    Use "remember" only when the user explicitly teaches or corrects an alias (e.g. "x means y"). \
    Omit empty fields.
    """

    static func user(query: String, memory: [MemoryEntry], apps: [String]) -> String {
        var s = ContextStore.promptBlock() + "\nSaved memory (learned aliases):\n"
        if memory.isEmpty { s += "(empty)\n" }
        for e in memory {
            s += "- \"\(e.phrase)\""
            if let n = e.note { s += " = \(n)" }
            if let a = e.actions, let d = try? JSONEncoder().encode(a), let t = String(data: d, encoding: .utf8) { s += " -> \(t)" }
            s += "\n"
        }
        s += "\nInstalled apps (sample): \(apps.prefix(120).joined(separator: ", "))\n"
        s += "\nUser typed: \(query)\n"
        return s
    }

    static func installedApps() -> [String] {
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var names: [String] = []
        for d in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
            names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        return names.sorted()
    }

    /// Pulls the JSON object out of a model reply even if it wrapped it in fences or prose.
    static func parse(_ text: String) throws -> ModelReply {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else {
            throw LauncherError.provider("No JSON in reply: \(text.prefix(120))")
        }
        let data = Data(text[a...b].utf8)
        do { return try JSONDecoder().decode(ModelReply.self, from: data) }
        catch { throw LauncherError.provider("Bad reply format: \(text.prefix(120))") }
    }
}

enum LLM {
    static func ask(query: String) async throws -> ModelReply {
        let settings = Settings.shared
        let user = Prompt.user(query: query, memory: Memory.shared.relevant(to: query), apps: Prompt.installedApps())
        let text: String
        switch settings.provider {
        case .claude: text = try await ClaudeCLI.run(model: settings.model(for: .claude), user: user)
        case .gemini: text = try await Gemini.run(model: settings.model(for: .gemini), user: user)
        }
        return try Prompt.parse(text)
    }
}

/// Claude provider: shells out to the Claude Code CLI in print mode with every tool disabled,
/// so it can only return text. The app itself performs the (restricted) actions.
enum ClaudeCLI {
    static func findBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.local/bin/claude", home + "/.claude/local/claude"]
        if let c = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    static func run(model: String, user: String) async throws -> String {
        guard let bin = findBinary() else {
            throw LauncherError.provider("Claude Code CLI not found. Install it, or switch provider in the menu bar.")
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-p", user, "--model", model, "--output-format", "text",
                               "--system-prompt", Prompt.system,
                               "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                               "--no-session-persistence"]
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // Drain stdout before waiting so a full pipe can't deadlock.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 || text.isEmpty {
                    let e = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: LauncherError.provider("claude failed: \((e.isEmpty ? text : e).prefix(200))"))
                } else {
                    cont.resume(returning: text)
                }
            }
        }
    }
}

enum Gemini {
    static func run(model: String, user: String) async throws -> String {
        let key = Settings.shared.geminiKey
        guard !key.isEmpty else {
            throw LauncherError.provider("Set your Gemini API key from the menu bar icon.")
        }
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompt.system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LauncherError.provider("Gemini error: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = (obj["candidates"] as? [[String: Any]])?.first,
              let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LauncherError.provider("Unexpected Gemini response")
        }
        return text
    }
}
