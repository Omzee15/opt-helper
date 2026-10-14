import AppKit

/// Something that can play music: a music app, or a browser with a YouTube (Music) tab.
struct MusicApp: Equatable {
    enum Kind { case spotify, music, chromium, safari }
    let kind: Kind
    let name: String      // AppleScript target
    let bundleID: String

    static let spotify = MusicApp(kind: .spotify, name: "Spotify", bundleID: "com.spotify.client")
    static let music = MusicApp(kind: .music, name: "Music", bundleID: "com.apple.Music")
    static let browsers = [
        MusicApp(kind: .chromium, name: "Google Chrome", bundleID: "com.google.Chrome"),
        MusicApp(kind: .chromium, name: "Brave Browser", bundleID: "com.brave.Browser"),
        MusicApp(kind: .chromium, name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        MusicApp(kind: .chromium, name: "Arc", bundleID: "company.thebrowser.Browser"),
        MusicApp(kind: .chromium, name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
        MusicApp(kind: .chromium, name: "Chromium", bundleID: "org.chromium.Chromium"),
        MusicApp(kind: .safari, name: "Safari", bundleID: "com.apple.Safari"),
    ]
    static let all = [spotify, music] + browsers

    var isBrowser: Bool { kind == .chromium || kind == .safari }
    /// Only script apps that are already open: `tell application` would launch them.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Where to turn on page scripting, which browsers keep off by default.
    var scriptingHint: String {
        kind == .safari
            ? "For play state and controls: Safari › Develop › Allow JavaScript from Apple Events"
            : "For play state and controls: \(name) › View › Developer › Allow JavaScript from Apple Events"
    }
}

struct Track: Equatable {
    var app: MusicApp
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var position: Double
    var duration: Double
    var artworkURL: String
    /// Browser tab the track plays in.
    var tabURL = ""
    /// False when a browser blocks page scripting: the track comes from the tab title only,
    /// so play state is a guess and the controls can't reach the page.
    var controllable = true

    var key: String { "\(app.name)|\(title)|\(album)" }
}

/// Reads and controls Spotify, Apple Music and YouTube / YouTube Music tabs in browsers
/// over AppleScript. Polls only while the notch dashboard is visible. Scripts run on one
/// serial background queue so they never stall UI.
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published var message: String?
    /// When `track.position` was read, so the progress bar can advance between polls.
    private(set) var polledAt = Date()

    private let queue = DispatchQueue(label: "dev.buildc3.opthelper.music")
    private var scripts: [String: NSAppleScript] = [:]  // touched only on `queue`
    private var timer: Timer?
    private var artworkKey: String?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        queue.async {
            let t = self.poll()
            DispatchQueue.main.async { self.apply(t) }
        }
    }

    // MARK: Controls

    func playPause() {
        guard let t = track else { return }
        guard t.controllable else { message = t.app.scriptingHint; return }
        track?.playing.toggle()  // optimistic, so the record stops/starts immediately
        if t.app.isBrowser { pageCommand(t, Self.jsPlayPause) } else { command(t.app, "playpause") }
    }

    func next() { step(app: "next track", js: Self.jsNext) }
    func previous() { step(app: "previous track", js: Self.jsPrevious) }

    private func step(app verb: String, js: String) {
        guard let t = track else { return }
        guard t.controllable else { message = t.app.scriptingHint; return }
        if t.app.isBrowser { pageCommand(t, js) } else { command(t.app, verb) }
    }

    func play(_ f: FavoritePlaylist) {
        let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch f.source {
        case .appleMusic:
            run("tell application \"Music\" to play playlist \"\(Self.escape(v))\"", then: f.name)
        case .spotify:
            let uri = Self.spotifyURI(v)
            let src = "tell application \"Spotify\" to play track \"\(Self.escape(uri))\""
            if MusicApp.spotify.isRunning {
                run(src, then: f.name)
            } else {
                // A cold Spotify ignores scripted play until it has finished launching.
                if let u = URL(string: uri) { NSWorkspace.shared.open(u) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.run(src, then: f.name) }
            }
        case .link:
            if let u = URL(string: v), u.scheme != nil { NSWorkspace.shared.open(u) }
            else { message = "\"\(v)\" is not a link" }
        }
    }

    // MARK: Internals

    private func command(_ app: MusicApp, _ verb: String) {
        run("tell application \"\(app.name)\" to \(verb)", then: nil)
    }

    /// Runs `js` in the tab the track plays in (or, if it navigated, the first YouTube tab).
    private func pageCommand(_ t: Track, _ js: String) {
        let exec = t.app.kind == .safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
        let src = """
        tell application "\(t.app.name)"
            set target to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u is "\(Self.escape(t.tabURL))" then
                        \(exec)
                        return
                    end if
                    if target is missing value and (u contains "music.youtube.com" or u contains "youtube.com/watch") then set target to t
                end repeat
            end repeat
            if target is not missing value then
                set t to target
                \(exec)
            end if
        end tell
        """
        run(src, then: nil)
    }

    private func run(_ source: String, then label: String?) {
        queue.async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            let msg = err.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Couldn't control the player" }
            DispatchQueue.main.async {
                self.message = msg ?? label.map { "Playing \($0)" }
                if self.message != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.message = nil }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
            let t = self.poll()
            DispatchQueue.main.async { self.apply(t) }
        }
    }

    private func apply(_ t: Track?) {
        polledAt = Date()
        if track != t { track = t }
        guard let t else { artwork = nil; artworkKey = nil; return }
        guard t.key != artworkKey else { return }
        artworkKey = t.key
        artwork = nil
        loadArtwork(for: t)
    }

    private func loadArtwork(for t: Track) {
        let key = t.key
        let deliver: (NSImage?) -> Void = { img in
            DispatchQueue.main.async { if self.artworkKey == key { self.artwork = img } }
        }
        if let u = URL(string: t.artworkURL), u.scheme?.hasPrefix("http") == true {
            URLSession.shared.dataTask(with: u) { data, _, _ in deliver(data.flatMap(NSImage.init(data:))) }.resume()
        } else if t.app.kind == .music {
            queue.async {
                let d = self.execute("art", "tell application \"Music\" to try\nreturn raw data of artwork 1 of current track\nend try")
                deliver(d?.data.isEmpty == false ? NSImage(data: d!.data) : nil)
            }
        }
    }

    /// Prefers something known to be playing, then a browser tab whose state can't be read
    /// (likely playing, since it's open on a song), then anything paused.
    private func poll() -> Track? {
        var best: (rank: Int, track: Track)?
        for app in MusicApp.all where app.isRunning {
            for t in app.isBrowser ? readBrowser(app) : [readApp(app)].compactMap({ $0 }) {
                let rank = t.playing ? (t.controllable ? 0 : 1) : 2
                if rank == 0 { return t }
                if best == nil || rank < best!.rank { best = (rank, t) }
            }
        }
        return best?.track
    }

    private func readApp(_ app: MusicApp) -> Track? {
        // Spotify reports duration in ms; Music in seconds.
        let duration = app.kind == .spotify ? "(duration of t) / 1000" : "duration of t"
        let art = app.kind == .spotify ? "artwork url of t" : "\"\""
        let src = """
        tell application "\(app.name)"
            try
                if player state is stopped then return {}
                set t to current track
                return {player state is playing, name of t, artist of t, album of t, player position, \(duration), \(art)}
            on error
                return {}
            end try
        end tell
        """
        guard let d = execute(app.name, src), d.numberOfItems >= 7 else { return nil }
        func s(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        return Track(app: app, title: s(2), artist: s(3), album: s(4),
                     playing: d.atIndex(1)?.booleanValue ?? false,
                     position: d.atIndex(5)?.doubleValue ?? 0,
                     duration: d.atIndex(6)?.doubleValue ?? 0,
                     artworkURL: s(7))
    }

    /// Every YouTube Music / YouTube video tab in `app`. Reads the page's media session when
    /// the browser allows scripting, otherwise falls back to the tab title.
    private func readBrowser(_ app: MusicApp) -> [Track] {
        let exec = app.kind == .safari ? "do JavaScript \"\(Self.jsRead)\" in t" : "execute t javascript \"\(Self.jsRead)\""
        let title = app.kind == .safari ? "name of t" : "title of t"
        let src = """
        tell application "\(app.name)"
            set out to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "music.youtube.com" or u contains "youtube.com/watch" then
                        try
                            set r to \(exec)
                            if r is missing value then set r to ""
                            set end of out to {"js", r, u}
                        on error
                            set end of out to {"title", \(title), u}
                        end try
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
        guard let d = execute(app.name, src), d.numberOfItems > 0 else { return [] }
        var tracks: [Track] = []
        for i in 1...d.numberOfItems {
            guard let item = d.atIndex(i), item.numberOfItems >= 3 else { continue }
            let mode = item.atIndex(1)?.stringValue, payload = item.atIndex(2)?.stringValue ?? ""
            let url = item.atIndex(3)?.stringValue ?? ""
            let site = url.contains("music.youtube.com") ? "YouTube Music" : "YouTube"
            if mode == "js" {
                guard let data = payload.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let artist = (j["a"] as? String) ?? ""
                tracks.append(Track(app: app, title: Self.cleanTitle((j["t"] as? String) ?? ""),
                                    artist: artist.isEmpty ? site : artist, album: (j["al"] as? String) ?? "",
                                    playing: (j["p"] as? Bool) ?? false,
                                    position: (j["pos"] as? Double) ?? 0, duration: (j["d"] as? Double) ?? 0,
                                    artworkURL: (j["art"] as? String) ?? "", tabURL: url))
            } else {
                let name = Self.cleanTitle(payload)
                guard !name.isEmpty, name != site else { continue }  // tab open but nothing chosen yet
                tracks.append(Track(app: app, title: name, artist: "\(site) in \(app.name)", album: "",
                                    playing: true, position: 0, duration: 0, artworkURL: "",
                                    tabURL: url, controllable: false))
            }
        }
        return tracks
    }

    /// "(3) Song - YouTube Music" → "Song".
    private static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        for suffix in [" - YouTube Music", " - YouTube"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t
    }

    // Page scripts. Single quotes only: they're embedded in AppleScript string literals.
    private static let jsRead = "(function(){var v=document.querySelector('video');var m=navigator.mediaSession&&navigator.mediaSession.metadata;if(!v&&!m)return '';var a=(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';return JSON.stringify({t:m&&m.title?m.title:document.title,a:m?m.artist:'',al:m?m.album:'',p:v?(!v.paused&&!v.ended):false,pos:v?v.currentTime:0,d:(v&&isFinite(v.duration))?v.duration:0,art:a});})()"
    private static let jsPlayPause = "(function(){var b=document.querySelector('#play-pause-button, .ytp-play-button');if(b){b.click();return;}var v=document.querySelector('video');if(v){v.paused?v.play():v.pause();}})()"
    private static let jsNext = "(function(){var b=document.querySelector('.next-button, .ytp-next-button');if(b)b.click();})()"
    private static let jsPrevious = "(function(){var b=document.querySelector('.previous-button, .ytp-prev-button');if(b){b.click();return;}var v=document.querySelector('video');if(v)v.currentTime=0;})()"

    /// Compiles once per key, then reuses. Call only on `queue`.
    private func execute(_ key: String, _ source: String) -> NSAppleEventDescriptor? {
        let script = scripts[key] ?? NSAppleScript(source: source)
        scripts[key] = script
        var err: NSDictionary?
        return script?.executeAndReturnError(&err)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// "https://open.spotify.com/intl-de/playlist/ID?si=…" → "spotify:playlist:ID".
    static func spotifyURI(_ v: String) -> String {
        guard !v.hasPrefix("spotify:"), let u = URL(string: v), u.host?.contains("spotify.com") == true else { return v }
        let parts = u.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        return parts.isEmpty ? v : "spotify:" + parts.joined(separator: ":")
    }
}

/// Favorites shared by the dashboard and the preferences window.
final class Favorites: ObservableObject {
    static let shared = Favorites()
    @Published var items = Settings.shared.favorites {
        didSet { Settings.shared.favorites = items }
    }
}
