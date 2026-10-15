import AppKit
import SwiftUI

/// Adds records to the music library (stored with the favorites), from Spotify and YouTube
/// Music links or from whatever is playing. Links get their title and cover from the public
/// oEmbed endpoints of Spotify and YouTube, so no account or developer app is needed.
enum MusicLibrary {
    /// Spotify links in a drag or paste (Spotify drags its songs and playlists as open.spotify.com links).
    /// Adds them and returns true; returns false when there are none, or files are present.
    @discardableResult
    static func add(from pb: NSPasteboard) -> Bool {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return false
        }
        var candidates = ((pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).map(\.absoluteString)
        if let s = pb.string(forType: .string) {
            candidates += s.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        }
        var seen = Set<String>()
        let uris = candidates.compactMap(spotifyURI).filter { seen.insert($0).inserted }
        guard !uris.isEmpty else { return false }
        for uri in uris { add(FavoritePlaylist(name: "Spotify " + (uri.split(separator: ":").dropFirst().first ?? ""), source: .spotify, value: uri)) }
        return true
    }

    /// A link typed or pasted into the library: a Spotify link or URI, or a YouTube Music link.
    /// Returns a note for the library header.
    static func add(link raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uri = spotifyURI(s) {
            if contains(uri) { return "Already in your library" }
            add(FavoritePlaylist(name: "Spotify " + (uri.split(separator: ":").dropFirst().first ?? ""), source: .spotify, value: uri))
            return "Added"
        }
        if let u = URL(string: s), u.host?.hasSuffix("youtube.com") == true || u.host == "youtu.be" {
            if contains(s) { return "Already in your library" }
            add(FavoritePlaylist(name: "YouTube Music", source: .link, value: s))
            return "Added"
        }
        return "Paste a Spotify or YouTube Music link"
    }

    /// spotify:track|album|playlist|artist|show|episode:ID, from a URI or open.spotify.com link.
    static func spotifyURI(_ s: String) -> String? {
        let uri = NowPlaying.spotifyURI(s.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify",
              ["track", "album", "playlist", "artist", "show", "episode"].contains(parts[1]) else { return nil }
        return uri
    }

    /// Adds what's playing now: the Spotify song, or the YouTube Music tab as a link.
    static func addPlaying() -> String {
        guard let t = NowPlaying.shared.track else { return "Nothing is playing" }
        let art = t.artworkURL.isEmpty ? nil : t.artworkURL
        switch t.site {
        case .spotify:
            guard let uri = spotifyURI(t.link) else { return "Couldn't find the song's Spotify link" }
            add(FavoritePlaylist(name: t.title, source: .spotify, value: uri, artwork: art, subtitle: t.artist))
        case .youtubeMusic:
            add(FavoritePlaylist(name: t.title, source: .link, value: t.link, artwork: art, subtitle: t.artist))
        }
        return "Added \(t.title)"
    }

    static func contains(_ value: String) -> Bool {
        Favorites.shared.items.contains { $0.value == value }
    }

    static func add(_ r: FavoritePlaylist) {
        guard !contains(r.value) else { return }
        Favorites.shared.items.append(r)
        if r.artwork == nil { fillIn(r) }
    }

    /// Title and cover for a bare Spotify or YouTube Music link.
    private static func fillIn(_ r: FavoritePlaylist) {
        var c: URLComponents?
        let subtitle: String
        let parts = r.value.split(separator: ":")
        if r.source == .spotify, parts.count == 3 {
            c = URLComponents(string: "https://open.spotify.com/oembed")
            c?.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
            subtitle = String(parts[1]).capitalized
        } else if r.source == .link, r.value.contains("youtube.com") || r.value.contains("youtu.be") {
            // YouTube's oEmbed doesn't know the music. host; the same paths work on www.
            c = URLComponents(string: "https://www.youtube.com/oembed")
            c?.queryItems = [URLQueryItem(name: "url", value: r.value.replacingOccurrences(of: "music.youtube.com", with: "www.youtube.com")),
                             URLQueryItem(name: "format", value: "json")]
            subtitle = "YouTube Music"
        } else { return }
        guard let url = c?.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                guard let i = Favorites.shared.items.firstIndex(where: { $0.id == r.id }) else { return }
                if let t = j["title"] as? String, !t.isEmpty { Favorites.shared.items[i].name = t }
                Favorites.shared.items[i].artwork = j["thumbnail_url"] as? String
                Favorites.shared.items[i].subtitle = (j["author_name"] as? String).map { subtitle == "YouTube Music" ? $0 : subtitle } ?? subtitle
            }
        }.resume()
    }
}

/// Cover art fetched once per URL and kept in memory.
enum ArtworkCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: String?) async -> NSImage? {
        guard let url, let u = URL(string: url), u.scheme?.hasPrefix("http") == true else { return nil }
        if let hit = cache.object(forKey: url as NSString) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSString)
        return img
    }
}

// MARK: Vinyl

/// A record: grooves, a label showing the cover art (or a plain red label), and the spindle hole.
struct VinylRecord: View {
    var artwork: NSImage?
    var size: CGFloat
    /// Label diameter as a share of the record; bigger keeps the cover readable when tiny.
    var label: CGFloat = 0.38
    /// A light rim, so a small record stands out against the black notch.
    var rim = false

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(0..<9) { i in
                Circle()
                    .stroke(Color.white.opacity(i % 3 == 0 ? 0.09 : 0.04), lineWidth: max(0.4, size / 190))
                    .padding(size * CGFloat(4 + i * 4) / 112)
            }
            if rim { Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: max(0.75, size / 30)) }
            labelView.frame(width: size * label, height: size * label).clipShape(Circle())
            Circle().fill(Color(white: 0.75)).frame(width: max(2, size * 0.045), height: max(2, size * 0.045))
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var labelView: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            // Blank label; the stripe makes the spin visible.
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.85, green: 0.33, blue: 0.24), Color(red: 0.65, green: 0.2, blue: 0.16)],
                                             startPoint: .top, endPoint: .bottom))
                Capsule().fill(Color.white.opacity(0.35)).frame(width: size * 0.22, height: max(1, size / 56)).offset(y: -size * 0.09)
            }
        }
    }
}

/// A record that turns at 33⅓ rpm while `playing`, and holds its angle when stopped.
struct SpinningRecord: View {
    var playing: Bool
    var artwork: NSImage?
    var size: CGFloat
    var label: CGFloat = 0.38
    var rim = false

    @State private var baseAngle: Double = 0
    @State private var spinningSince: Date?
    private let degreesPerSecond = 33.3 / 60 * 360

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            VinylRecord(artwork: artwork, size: size, label: label, rim: rim).rotationEffect(.degrees(angle(at: ctx.date)))
        }
        .frame(width: size, height: size)
        .onAppear { if playing { spinningSince = Date() } }
        .onChange(of: playing) { now in
            if now { spinningSince = Date() } else {
                baseAngle = angle(at: Date())
                spinningSince = nil
            }
        }
    }

    private func angle(at date: Date) -> Double {
        baseAngle + (spinningSince.map { date.timeIntervalSince($0) } ?? 0) * degreesPerSecond
    }
}

/// The record beside the collapsed notch while music plays.
struct NotchPeekRecord: View {
    @ObservedObject private var player = NowPlaying.shared
    var size: CGFloat

    var body: some View {
        SpinningRecord(playing: player.track?.playing ?? false, artwork: player.artwork, size: size, label: 0.6, rim: true)
    }
}

// MARK: Library view

/// A record being dragged out of the library, at `point` in the dashboard's coordinate space.
struct RecordDrag: Equatable {
    var record: FavoritePlaylist
    var artwork: NSImage?
    var point: CGPoint
}

/// The crate of records shown in place of the player controls and shelf. Records are
/// dragged onto the turntable to play them (see `DashboardView`).
struct LibraryView: View {
    @ObservedObject private var favorites = Favorites.shared
    @Binding var drag: RecordDrag?
    /// Where a drag ended, in the dashboard's coordinate space.
    var onDrop: (FavoritePlaylist, CGPoint) -> Void

    @State private var link = ""
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Library").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                TextField("Paste a Spotify or YouTube Music link", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit { addLink() }
                if let n = note {
                    Text(n).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Button {
                    show(MusicLibrary.addPlaying())
                } label: {
                    Label("Add playing", systemImage: "plus").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add the song that's playing now to your library")
            }
            content.frame(height: 98)
        }
    }

    private func addLink() {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let n = MusicLibrary.add(link: link)
        if n == "Added" { link = "" }
        show(n)
    }

    private func show(_ n: String) {
        note = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if note == n { note = nil } }
    }

    @ViewBuilder private var content: some View {
        if favorites.items.isEmpty {
            placeholder("In Spotify, right-click a playlist › Share › Copy link, then paste it above or press ⌘V here. You can also drag songs and playlists from the Spotify app onto the notch.")
        } else {
            crate(favorites.items)
        }
    }

    private func crate(_ items: [FavoritePlaylist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(items) { r in
                    Sleeve(record: r, lifted: drag?.record.value == r.value, drag: $drag, onDrop: onDrop)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

/// A record sleeve with the disc peeking out. Drag it onto the turntable to play it.
private struct Sleeve: View {
    let record: FavoritePlaylist
    /// The disc is out of its sleeve, being dragged.
    let lifted: Bool
    @Binding var drag: RecordDrag?
    var onDrop: (FavoritePlaylist, CGPoint) -> Void

    @ObservedObject private var favorites = Favorites.shared
    @State private var art: NSImage?

    private let cover: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .leading) {
                VinylRecord(artwork: art, size: cover - 4)
                    .offset(x: lifted ? 0 : 16)
                    .opacity(lifted ? 0 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lifted)
                sleeve
            }
            .frame(width: cover + 16, height: cover, alignment: .leading)
            Text(record.name.isEmpty ? record.value : record.name)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
            if let s = record.subtitle, !s.isEmpty {
                Text(s).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(width: cover + 16, alignment: .leading)
        .contentShape(Rectangle())
        .help("Drag onto the turntable to play")
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(DashboardView.space))
                .onChanged { v in
                    if drag == nil { NSCursor.closedHand.set() }
                    drag = RecordDrag(record: record, artwork: art, point: v.location)
                }
                .onEnded { v in
                    NSCursor.arrow.set()
                    drag = nil
                    onDrop(record, v.location)
                }
        )
        .onTapGesture(count: 2) { NowPlaying.shared.play(record) }
        .contextMenu {
            Button("Play") { NowPlaying.shared.play(record) }
            Button("Remove from library") { favorites.items.removeAll { $0.id == record.id } }
        }
        .task(id: record.artwork) { art = await ArtworkCache.image(record.artwork) }
    }

    private var sleeve: some View {
        Group {
            if let art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: DashboardView.symbol(record.source)).font(.system(size: 18)).foregroundStyle(.secondary))
            }
        }
        .frame(width: cover, height: cover)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.5), radius: 3, x: 2)
    }
}
