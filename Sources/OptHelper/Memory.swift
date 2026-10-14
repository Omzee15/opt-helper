import Foundation

/// A remembered shortcut: a short phrase mapped to the actions it resolves to.
struct MemoryEntry: Codable {
    var phrase: String
    var note: String?
    var actions: [Action]?
    var uses: Int = 0
}

extension MemoryEntry {
    /// One-line description of what the entry does, for the menu.
    var summary: String {
        if let a = actions, !a.isEmpty {
            return a.map { x in
                switch x.type {
                case .openURL: return URL(string: x.url ?? "").map { ($0.host ?? "") + $0.path } ?? "url"
                case .openApp: return x.app ?? "app"
                case .newWindow: return "window: " + (x.app ?? "")
                case .openFolder: return "folder: " + (x.path ?? "")
                case .runShortcut: return "run: " + (x.shortcut ?? "") + ((x.ports ?? []).isEmpty ? "" : " " + x.ports!.map(String.init).joined(separator: ","))
                }
            }.joined(separator: " + ")
        }
        return note ?? ""
    }
}

/// Persistent personal context, stored as plain JSON the user can edit:
/// ~/Library/Application Support/OptHelper/memory.json
final class Memory {
    static let shared = Memory()

    let url: URL
    private(set) var entries: [MemoryEntry] = []

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OptHelper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
        load()
        if !FileManager.default.fileExists(atPath: url.path) { save() }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        entries = e
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    func remove(phrase: String) {
        let key = Memory.normalize(phrase)
        entries.removeAll { Memory.normalize($0.phrase) == key }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Exact match on a phrase that already has actions → no model call needed.
    func exact(_ query: String) -> MemoryEntry? {
        let q = Memory.normalize(query)
        return entries.first { Memory.normalize($0.phrase) == q && !($0.actions ?? []).isEmpty }
    }

    func upsert(phrase: String, note: String?, actions: [Action]?) {
        let key = Memory.normalize(phrase)
        guard !key.isEmpty else { return }
        if let i = entries.firstIndex(where: { Memory.normalize($0.phrase) == key }) {
            if let note { entries[i].note = note }
            if let actions, !actions.isEmpty { entries[i].actions = actions }
            entries[i].uses += 1
        } else {
            entries.append(MemoryEntry(phrase: phrase, note: note, actions: actions, uses: 1))
        }
        save()
    }

    /// The entries most relevant to a query (word overlap), then most used, capped for prompt size.
    func relevant(to query: String, limit: Int = 40) -> [MemoryEntry] {
        let words = Set(Memory.normalize(query).split(separator: " ").map(String.init))
        func score(_ e: MemoryEntry) -> Int {
            let text = Memory.normalize(e.phrase + " " + (e.note ?? ""))
            let overlap = words.filter { text.contains($0) }.count
            return overlap * 100 + min(e.uses, 50)
        }
        return Array(entries.sorted { score($0) > score($1) }.prefix(limit))
    }
}
