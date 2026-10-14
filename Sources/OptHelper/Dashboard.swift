import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What the notch shows when it pops open on hover.
struct DashboardView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var player = NowPlaying.shared
    @ObservedObject private var favorites = Favorites.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Phonograph(playing: player.track?.playing ?? false, artwork: player.artwork) { player.playPause() }
            VStack(alignment: .leading, spacing: 10) {
                nowPlaying
                favoritesRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShelfView()
                .frame(width: 210)
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = player.track?.app.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.track?.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(player.message ?? player.track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") }
                         ?? "Open Spotify or Music, or pick a playlist")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            if let t = player.track, t.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let elapsed = t.playing ? ctx.date.timeIntervalSince(player.polledAt) : 0
                    ProgressView(value: min(t.position + elapsed, t.duration), total: t.duration)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.8))
                        .controlSize(.mini)
                }
            }
            HStack(spacing: 18) {
                control("backward.fill") { player.previous() }
                control(player.track?.playing == true ? "pause.fill" : "play.fill", size: 18) { player.playPause() }
                control("forward.fill") { player.next() }
            }
            .disabled(player.track == nil)
            .opacity(player.track == nil || player.track?.controllable == false ? 0.35 : 1)
            if let t = player.track, !t.controllable {
                Text(t.app.scriptingHint)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(favorites.items) { f in
                    Button { player.play(f) } label: {
                        Label(f.name.isEmpty ? f.value : f.name, systemImage: Self.symbol(f.source))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help(f.value)
                }
                Button { model.onOpenSettings?() } label: {
                    Label(favorites.items.isEmpty ? "Add favorite playlists" : "Edit", systemImage: "plus")
                        .font(.system(size: 11))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    static func symbol(_ s: FavoritePlaylist.Source) -> String {
        switch s {
        case .appleMusic: return "music.note"
        case .spotify: return "music.note.list"
        case .link: return "link"
        }
    }
}

/// Small strip in the notch band itself: left of the notch shows what's playing,
/// right of it holds the search and settings buttons. Mirrors a menu bar.
struct DashboardHeader: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var player = NowPlaying.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: player.track?.playing == true ? "waveform" : "music.note")
                    .foregroundStyle(player.track?.playing == true ? Color.green : Color.secondary)
                Text(player.track.map { $0.artist.isEmpty ? $0.title : "\($0.title) · \($0.artist)" } ?? "OptHelper")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width + 12)  // the physical notch hides this part
            HStack(spacing: 12) {
                headerButton("magnifyingglass", help: "Search (\(Settings.shared.hotKey.title))") { model.onSearch?() }
                headerButton("tray.full", help: "Open shelf folder") { Shelf.shared.revealFolder() }
                headerButton("gearshape", help: "Preferences") { model.onOpenSettings?() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 22)
        .frame(height: model.notch.height)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

// MARK: Phonograph

/// A turntable whose record spins while music plays. The label shows the album art,
/// or stays a blank label when there is none. The tonearm swings onto the record on play.
struct Phonograph: View {
    var playing: Bool
    var artwork: NSImage?
    /// Called when the tonearm is dropped onto the record (while paused) or lifted off it (while playing).
    var onToggle: () -> Void = {}

    @State private var baseAngle: Double = 0
    @State private var spinningSince: Date?
    /// Tonearm angle while it's being dragged; nil when it rests where `playing` puts it.
    @State private var dragAngle: Double?
    @State private var dragStart: (pointer: Double, arm: Double)?

    private static let restAngle: Double = 0    // off the record
    private static let playAngle: Double = 20   // stylus in the grooves
    private static let maxAngle: Double = 32    // inner edge of the record
    private static let onRecord: Double = 10    // past this, a dropped arm lands on the record

    private let size = CGSize(width: 150, height: 128)
    private let disc: CGFloat = 112
    private let pivot = CGPoint(x: 134, y: 16)
    private let degreesPerSecond = 33.3 / 60 * 360  // 33⅓ rpm

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.13), Color(red: 0.2, green: 0.12, blue: 0.07)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))

            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
                record.rotationEffect(.degrees(angle(at: ctx.date)))
            }
            .frame(width: disc, height: disc)
            .overlay(sheen)
            .offset(x: 8, y: (size.height - disc) / 2)

            tonearm
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "phonograph")
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

    private var record: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(0..<9) { i in
                Circle()
                    .stroke(Color.white.opacity(i % 3 == 0 ? 0.09 : 0.04), lineWidth: 0.6)
                    .padding(CGFloat(4 + i * 4))
            }
            label.frame(width: disc * 0.38, height: disc * 0.38).clipShape(Circle())
            Circle().fill(Color(white: 0.75)).frame(width: 5, height: 5)  // spindle
        }
    }

    @ViewBuilder private var label: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            // Blank label; the stripe makes the spin visible.
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.85, green: 0.33, blue: 0.24), Color(red: 0.65, green: 0.2, blue: 0.16)],
                                             startPoint: .top, endPoint: .bottom))
                Capsule().fill(Color.white.opacity(0.35)).frame(width: disc * 0.22, height: 2).offset(y: -disc * 0.09)
            }
        }
    }

    /// Light reflection that stays still while the record turns underneath it.
    private var sheen: some View {
        Circle()
            .fill(AngularGradient(colors: [.clear, .white.opacity(0.1), .clear, .clear, .white.opacity(0.07), .clear],
                                  center: .center, angle: .degrees(30)))
            .allowsHitTesting(false)
    }

    private var armPath: Path {
        Path { p in
            p.move(to: pivot)
            p.addLine(to: CGPoint(x: pivot.x, y: pivot.y + 54))
            p.addLine(to: CGPoint(x: pivot.x - 22, y: pivot.y + 78))
        }
    }

    private var tonearm: some View {
        ZStack(alignment: .topLeading) {
            armPath
                .stroke(Color(white: 0.82), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.6))
                .frame(width: 8, height: 13)
                .rotationEffect(.degrees(42))
                .position(x: pivot.x - 23, y: pivot.y + 80)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Only the arm itself is grabbable, with some slack around the thin rod.
        .contentShape(armPath.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round)))
        .rotationEffect(.degrees(dragAngle ?? (playing ? Self.playAngle : Self.restAngle)),
                        anchor: UnitPoint(x: pivot.x / size.width, y: pivot.y / size.height))
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: playing)
        .animation(dragAngle == nil ? .spring(response: 0.5, dampingFraction: 0.75) : nil, value: dragAngle)
        .gesture(armDrag)
        .onHover { inside in
            if dragStart == nil { (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        }
        .overlay(
            Circle().fill(Color(white: 0.5)).frame(width: 12, height: 12)
                .position(pivot)
                .allowsHitTesting(false)
        )
    }

    /// Swing the arm about its pivot: lift it off the record to pause, set it down to play.
    private var armDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("phonograph"))
            .onChanged { v in
                // Screen y grows downward, so a growing atan2 is a clockwise swing, toward the record.
                let pointer = Double(atan2(v.location.y - pivot.y, v.location.x - pivot.x)) * 180 / .pi
                if dragStart == nil {
                    dragStart = (pointer, dragAngle ?? (playing ? Self.playAngle : Self.restAngle))
                    NSCursor.closedHand.set()
                }
                guard let start = dragStart else { return }
                var delta = pointer - start.pointer
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                dragAngle = min(max(start.arm + delta, Self.restAngle - 4), Self.maxAngle)
            }
            .onEnded { _ in
                let landed = (dragAngle ?? 0) > Self.onRecord
                dragStart = nil
                NSCursor.arrow.set()
                if landed != playing { onToggle() }
                // Settle where playback actually is: if the player can't be controlled,
                // `playing` doesn't change and the arm swings back.
                dragAngle = nil
            }
    }
}

// MARK: Shelf

private struct ItemFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Drops anywhere on the island land here (see `NotchHostingView`), as does ⌘V.
struct ShelfView: View {
    @ObservedObject private var shelf = Shelf.shared
    private var targeted: Bool { shelf.dropTargeted }

    private let columns = [GridItem(.adaptive(minimum: 46, maximum: 54), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shelf").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !shelf.items.isEmpty {
                    Button("Clear") { shelf.clear() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.16),
                                  style: StrokeStyle(lineWidth: 1.2, dash: shelf.items.isEmpty || targeted ? [5, 4] : []))
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(targeted ? 0.08 : 0.03)))
                if shelf.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 18))
                        Text("Drop or ⌘V files here").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(shelf.items, id: \.self) { ShelfItem(url: $0) }
                        }
                        .padding(6)
                    }
                    .onPreferenceChange(ItemFramesKey.self) { shelf.itemFrames = $0 }
                }
            }
            .frame(height: 104)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { shelf.boxFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { shelf.boxFrame = $0 }
            })
        }
    }
}

private struct ShelfItem: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 30)
            Text(url.lastPathComponent)
                .font(.system(size: 8))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .frame(width: 48)
        .contentShape(Rectangle())
        .help(url.lastPathComponent)
        // Dragging out is started by NotchHostingView, which offers copies only.
        .background(GeometryReader { Color.clear.preference(key: ItemFramesKey.self, value: [url: $0.frame(in: .global)]) })
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Copy") { Shelf.shared.copyToClipboard(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove") { Shelf.shared.remove(url) }
        }
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 68, height: 60),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb = rep.nsImage
            }
        }
    }
}
