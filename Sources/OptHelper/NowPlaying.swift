import AppKit

/// A browser that can host a YouTube Music or Spotify web player tab, or the Spotify app.
struct MusicApp: Equatable {
    enum Kind { case chromium, safari, desktop }
    let kind: Kind
    let name: String      // AppleScript target
    let bundleID: String

    static let all = [
        MusicApp(kind: .chromium, name: "Google Chrome", bundleID: "com.google.Chrome"),
        MusicApp(kind: .chromium, name: "Brave Browser", bundleID: "com.brave.Browser"),
        MusicApp(kind: .chromium, name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        MusicApp(kind: .chromium, name: "Arc", bundleID: "company.thebrowser.Browser"),
        MusicApp(kind: .chromium, name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
        MusicApp(kind: .chromium, name: "Chromium", bundleID: "org.chromium.Chromium"),
        MusicApp(kind: .safari, name: "Safari", bundleID: "com.apple.Safari"),
    ]

    /// The installed Spotify app, scripted directly: no browser, page scripting or account needed.
    static let spotify = MusicApp(kind: .desktop, name: "Spotify", bundleID: "com.spotify.client")

    /// Only script apps that are already open: `tell application` would launch them.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Where to turn on page scripting, which browsers keep off by default.
    var scriptingHint: String {
        kind == .safari
            ? "For play state and controls: Safari › Develop › Allow JavaScript from Apple Events"
            : "For play state and controls: \(name) › View › Developer › Allow JavaScript from Apple Events"
    }

    /// AppleScript that runs `js` in tab `t`.
    func exec(_ js: String) -> String {
        kind == .safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
    }

    /// The browser links open in: the one picked in the menu, else the system default.
    static var preferred: MusicApp? {
        let name = Settings.shared.browser
        if let b = all.first(where: { $0.name == name }) { return b }
        let id = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://open.spotify.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return all.first { $0.bundleID == id }
    }
}

/// The players the turntable follows: web players in a browser tab, and the Spotify app.
enum MusicSite: String {
    case youtubeMusic = "YouTube Music", spotify = "Spotify"

    init?(url: String) {
        if url.contains("music.youtube.com") { self = .youtubeMusic }
        else if url.contains("open.spotify.com") { self = .spotify }
        else { return nil }
    }

    /// AppleScript test for a tab URL `u` on either site.
    static let tabTest = "(u contains \"music.youtube.com\" or u contains \"open.spotify.com\")"
}

struct Track: Equatable {
    var app: MusicApp
    var site: MusicSite
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
    /// open.spotify.com/track/… for Spotify, the tab URL for YouTube Music.
    var link = ""

    var key: String { "\(app.name)|\(title)|\(album)" }
}

/// Reads and controls the Spotify app, and YouTube Music and Spotify web player tabs in
/// browsers, over AppleScript. Apple Music and plain YouTube are ignored. Polls every
/// second while the dashboard is open, slower while the collapsed notch shows the record.
/// Scripts run on one serial background queue so they never stall UI.
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

    /// Polls every second while the dashboard is open.
    func start() { poll(every: 1) }

    /// Dashboard closed: keep a slow poll going if the collapsed notch shows the record, else stop.
    func idle() {
        if Settings.shared.notchPeek { poll(every: 3) } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll(every interval: TimeInterval) {
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
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
        t.app.kind == .desktop ? appCommand("playpause") : pageCommand(t, Self.jsPlayPause)
    }

    func next() { step(Self.jsNext, "next track") }
    func previous() { step(Self.jsPrevious, "previous track") }

    private func step(_ js: String, _ command: String) {
        guard let t = track else { return }
        guard t.controllable else { message = t.app.scriptingHint; return }
        t.app.kind == .desktop ? appCommand(command) : pageCommand(t, js)
    }

    private func appCommand(_ command: String) {
        run("tell application \"Spotify\" to \(command)", then: nil)
    }

    /// Plays a library record: Spotify records in the Spotify app (or, without it, the web
    /// player), links in the browser.
    func play(_ f: FavoritePlaylist) {
        let v = f.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch f.source {
        case .spotify:
            let parts = Self.spotifyURI(v).split(separator: ":")
            guard parts.count == 3, parts[0] == "spotify" else { message = "\"\(v)\" is not a Spotify link"; return }
            if Settings.shared.spotifyInApp, MusicApp.spotify.isInstalled {
                playInSpotifyApp(uri: parts.joined(separator: ":"), name: f.name)
            } else {
                playOnSpotifyWeb(kind: String(parts[1]), id: String(parts[2]), name: f.name)
            }
        case .link:
            if let u = URL(string: v), u.scheme != nil { NSWorkspace.shared.open(u) }
            else { message = "\"\(v)\" is not a link" }
        case .appleMusic:
            message = "Apple Music isn't supported. Use Spotify or YouTube Music links."
        }
    }

    /// Plays a spotify: URI (song, album, playlist, artist…) in the Spotify app, opening it
    /// first if needed. A freshly launched app ignores commands for a moment, so it retries.
    private func playInSpotifyApp(uri: String, name: String) {
        message = "Loading \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            if !MusicApp.spotify.isRunning, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicApp.spotify.bundleID) {
                let c = NSWorkspace.OpenConfiguration()
                c.activates = false
                NSWorkspace.shared.openApplication(at: app, configuration: c)
                for _ in 0..<20 where !MusicApp.spotify.isRunning { Thread.sleep(forTimeInterval: 0.5) }
                Thread.sleep(forTimeInterval: 2)
            }
            var started = false
            for _ in 0..<8 where !started {
                let r = Self.runScript("""
                tell application "Spotify"
                    play track "\(Self.escape(uri))"
                    delay 0.7
                    return (player state is playing)
                end tell
                """)
                started = r?.booleanValue == true
                if !started { Thread.sleep(forTimeInterval: 1) }
            }
            DispatchQueue.main.async {
                self.message = started ? "Playing \(name)" : "Couldn't start \(name) in Spotify. Is the Spotify app signed in?"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.message = nil }
                self.refresh()
            }
        }
    }

    /// Loads the record in an open Spotify web player tab (or a new one in the preferred
    /// browser), then presses its play button once the page has loaded.
    private func playOnSpotifyWeb(kind: String, id: String, name: String) {
        let url = "https://open.spotify.com/\(kind)/\(id)"
        message = "Loading \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let browsers = MusicApp.all.filter(\.isRunning)
            let reused = browsers.contains { b in
                Self.runScript("""
                tell application "\(b.name)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "open.spotify.com" then
                                set URL of t to "\(url)"
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
                """)?.booleanValue == true
            }
            if !reused, let u = URL(string: url) {
                if let b = MusicApp.preferred, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) {
                    NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(u)
                }
            }
            let js = Self.jsPlayEntity(id)
            var started = false
            for _ in 0..<15 where !started {
                Thread.sleep(forTimeInterval: 1)
                for b in MusicApp.all where b.isRunning {
                    let r = Self.runScript("""
                    tell application "\(b.name)"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if URL of t contains "\(id)" then return \(b.exec(js))
                            end repeat
                        end repeat
                        return ""
                    end tell
                    """)?.stringValue
                    if r == "ok" { started = true; break }
                }
            }
            DispatchQueue.main.async {
                self.message = started ? "Playing \(name)" : "Opened \(name) in Spotify; press play there"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.message = nil }
                self.refresh()
            }
        }
    }

    private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    // MARK: Internals

    /// Runs `js` in the tab the track plays in (or, if it navigated, the first music tab).
    private func pageCommand(_ t: Track, _ js: String) {
        let exec = t.app.exec(js)
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
                    if target is missing value and \(MusicSite.tabTest) then set target to t
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
        } else {
            deliver(nil)
        }
    }

    /// Prefers something known to be playing, then a tab whose state can't be read
    /// (likely playing, since it's open on a song), then anything paused.
    private func poll() -> Track? {
        var best: (rank: Int, track: Track)?
        func consider(_ t: Track) -> Bool {
            let rank = t.playing ? (t.controllable ? 0 : 1) : 2
            if best == nil || rank < best!.rank { best = (rank, t) }
            return rank == 0
        }
        if MusicApp.spotify.isRunning, let t = readSpotifyApp(), consider(t) { return t }
        for app in MusicApp.all where app.isRunning {
            for t in readBrowser(app) where consider(t) { return t }
        }
        return best?.track
    }

    /// The Spotify app's current track, unless it's stopped (nothing loaded).
    private func readSpotifyApp() -> Track? {
        let src = """
        tell application "Spotify"
            if player state is stopped then return {}
            set t to current track
            return {name of t, artist of t, album of t, (player state is playing), player position, duration of t, artwork url of t, spotify url of t}
        end tell
        """
        guard let d = execute("Spotify", src), d.numberOfItems >= 8 else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        let title = str(1)
        guard !title.isEmpty else { return nil }
        // Spotify reports the duration in milliseconds, the position in seconds.
        return Track(app: .spotify, site: .spotify, title: title, artist: str(2), album: str(3),
                     playing: d.atIndex(4)?.booleanValue ?? false,
                     position: d.atIndex(5)?.doubleValue ?? 0, duration: (d.atIndex(6)?.doubleValue ?? 0) / 1000,
                     artworkURL: str(7), tabURL: "", link: str(8))
    }

    /// Every YouTube Music and Spotify web player tab in `app`. Reads the page when the
    /// browser allows scripting, otherwise falls back to the tab title.
    private func readBrowser(_ app: MusicApp) -> [Track] {
        let title = app.kind == .safari ? "name of t" : "title of t"
        let src = """
        tell application "\(app.name)"
            set out to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if \(MusicSite.tabTest) then
                        try
                            set r to \(app.exec(Self.jsRead))
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
            guard let site = MusicSite(url: url) else { continue }
            if mode == "js" {
                guard let data = payload.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = j["t"] as? String, !name.isEmpty else { continue }
                let artist = (j["a"] as? String) ?? ""
                let link = (j["l"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                tracks.append(Track(app: app, site: site, title: Self.cleanTitle(name),
                                    artist: artist.isEmpty ? site.rawValue : artist, album: (j["al"] as? String) ?? "",
                                    playing: (j["p"] as? Bool) ?? false,
                                    position: (j["pos"] as? Double) ?? 0, duration: (j["d"] as? Double) ?? 0,
                                    artworkURL: (j["art"] as? String) ?? "", tabURL: url, link: link))
            } else {
                // Spotify titles a playing tab "Song • Artist"; idle tabs are "Spotify – Web Player…".
                let raw = Self.cleanTitle(payload)
                guard !raw.isEmpty, raw != site.rawValue, !raw.contains("Web Player") else { continue }
                let parts = raw.components(separatedBy: " • ")
                tracks.append(Track(app: app, site: site, title: parts[0],
                                    artist: parts.count > 1 ? parts[1] : "\(site.rawValue) in \(app.name)", album: "",
                                    playing: true, position: 0, duration: 0, artworkURL: "",
                                    tabURL: url, controllable: false, link: url))
            }
        }
        return tracks
    }

    /// "(3) Song - YouTube Music" → "Song".
    private static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        for suffix in [" - YouTube Music"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t
    }

    // Page scripts. Single quotes only (and unquoted attribute selectors): they're embedded
    // in AppleScript string literals. Spotify's player is found by its data-testid attributes.
    private static let jsRead = "(function(){var sp=location.host.indexOf('spotify')>=0;var m=navigator.mediaSession&&navigator.mediaSession.metadata;var art=(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';function q(s){return document.querySelector(s);}function tx(s){var e=q(s);return e?e.textContent.trim():'';}function tm(s){var t=tx(s),neg=t.charAt(0)=='-';var n=t.replace('-','').split(':').reduce(function(a,x){return a*60+(+x||0);},0);return neg?-n:n;}if(sp){var b=q('[data-testid=control-button-playpause]');var title=m&&m.title?m.title:tx('[data-testid=context-item-info-title]');if(!title)return '';var lab=b?(b.getAttribute('aria-label')||''):'';var pos=tm('[data-testid=playback-position]'),d=tm('[data-testid=playback-duration]');if(d<0)d=pos-d;var a=q('[data-testid=now-playing-widget] a[href*=track]')||q('[data-testid=context-item-info-title] a');return JSON.stringify({t:title,a:m?m.artist:tx('[data-testid=context-item-info-artist]'),al:m?m.album:'',p:navigator.mediaSession.playbackState=='playing'||lab=='Pause',pos:pos,d:d,art:art,l:a?a.href:''});}var v=q('video');if(!v&&!m)return '';return JSON.stringify({t:m&&m.title?m.title:document.title,a:m?m.artist:'',al:m?m.album:'',p:v?(!v.paused&&!v.ended):false,pos:v?v.currentTime:0,d:(v&&isFinite(v.duration))?v.duration:0,art:art});})()"
    private static let jsPlayPause = "(function(){var b=document.querySelector('#play-pause-button, [data-testid=control-button-playpause]');if(b){b.click();return;}var v=document.querySelector('video');if(v){v.paused?v.play():v.pause();}})()"
    private static let jsNext = "(function(){var b=document.querySelector('.next-button, [data-testid=control-button-skip-forward]');if(b)b.click();})()"
    private static let jsPrevious = "(function(){var b=document.querySelector('.previous-button, [data-testid=control-button-skip-back]');if(b){b.click();return;}var v=document.querySelector('video');if(v)v.currentTime=0;})()"

    /// Presses the big play button on a Spotify track/album/playlist page once it has loaded.
    /// Returns 'ok' when it's playing (or already was), 'wait' until then.
    private static func jsPlayEntity(_ id: String) -> String {
        "(function(){if(location.pathname.indexOf('\(id)')<0)return 'wait';var b=document.querySelector('[data-testid=action-bar-row] [data-testid=play-button]');if(!b)return 'wait';if((b.getAttribute('aria-label')||'').indexOf('Pause')==0)return 'ok';b.click();return 'ok';})()"
    }

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
