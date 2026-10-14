import AppKit
import UniformTypeIdentifiers

/// A scratch folder in the notch: drop or paste files and images in, drag them out elsewhere.
/// Items are copies, so moving or deleting the originals doesn't affect the shelf.
final class Shelf: ObservableObject {
    static let shared = Shelf()

    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let f = caches.appendingPathComponent("dev.buildc3.opthelper/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    @Published private(set) var items: [URL] = []
    /// A drag is hovering over the island; the shelf lights up to show it'll land there.
    @Published var dropTargeted = false
    /// Where each item and the visible shelf box sit in the island's view (top-left origin),
    /// so the hosting view can tell which item a drag out starts on.
    var itemFrames: [URL: CGRect] = [:]
    var boxFrame: CGRect = .zero
    private let io = DispatchQueue(label: "dev.buildc3.opthelper.shelf")
    private let promiseQueue = OperationQueue()

    init() { reload() }

    /// Newest first.
    func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        items = urls.sorted { date($0) > date($1) }
    }

    // MARK: Adding

    /// ⌘V or a drop into the shelf: files, then file promises, then images, then text.
    /// Always copies; the originals are left where they were.
    @discardableResult
    func paste(from pb: NSPasteboard = .general) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Dragging a shelf item back onto the island shouldn't duplicate it.
            let outside = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL }
            outside.forEach { copyIn($0) }
            return !outside.isEmpty
        }
        // Photos, Mail attachments, …: the source writes the file only once asked.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for r in promises {
                r.receivePromisedFiles(atDestination: tmp, options: [:], operationQueue: promiseQueue) { url, error in
                    if error == nil { self.copyIn(url, now: true) }
                }
            }
            return true
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            write(png, name: "Pasted image \(Self.stamp()).png")
            return true
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            write(Data(s.utf8), name: "Pasted text \(Self.stamp()).txt")
            return true
        }
        return false
    }

    // MARK: Managing

    func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    func clear() {
        items.forEach { try? FileManager.default.removeItem(at: $0) }
        reload()
    }

    func revealFolder() { NSWorkspace.shared.open(folder) }

    // MARK: Internals

    private func copyIn(_ src: URL, now: Bool = false) {
        let work = {
            let dst = self.destination(for: src.lastPathComponent)
            try? FileManager.default.copyItem(at: src, to: dst)
            DispatchQueue.main.async { self.reload() }
        }
        if now { io.sync(execute: work) } else { io.async(execute: work) }
    }

    private func write(_ data: Data, name: String) {
        io.async {
            try? data.write(to: self.destination(for: name))
            DispatchQueue.main.async { self.reload() }
        }
    }

    /// "photo.png" → "photo 2.png" if taken.
    private func destination(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent(safe)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
