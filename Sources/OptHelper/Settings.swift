import Foundation

enum Provider: String, CaseIterable {
    case claude, gemini

    var title: String { self == .claude ? "Claude" : "Gemini" }

    var models: [String] {
        switch self {
        case .claude: return ["haiku", "sonnet", "opus"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        }
    }
}

struct HotKeyChoice: Equatable {
    let title: String
    let keyCode: UInt32      // kVK_Space = 49
    let carbonModifiers: UInt32

    static let optionSpace = HotKeyChoice(title: "⌥ Space", keyCode: 49, carbonModifiers: 0x0800)
    // Conflicts with Spotlight unless Spotlight's shortcut is disabled in System Settings.
    static let commandSpace = HotKeyChoice(title: "⌘ Space", keyCode: 49, carbonModifiers: 0x0100)
    static let all = [optionSpace, commandSpace]
}

/// A record in the notch music library: a playlist, album or song.
struct FavoritePlaylist: Codable, Equatable, Identifiable {
    enum Source: String, Codable, CaseIterable {
        case appleMusic, spotify, link
        var title: String {
            switch self {
            case .appleMusic: return "Apple Music"
            case .spotify: return "Spotify"
            case .link: return "Link"
            }
        }
        /// What `value` holds for this source.
        var hint: String {
            switch self {
            case .appleMusic: return "Not supported; use a Spotify or YouTube Music link"
            case .spotify: return "spotify:playlist:… or open.spotify.com link"
            case .link: return "Any URL, e.g. a YouTube Music playlist"
            }
        }
    }
    var id = UUID()
    var name: String
    var source: Source
    var value: String
    /// Cover art URL and a second line (artist, owner), filled in for records in the music library.
    var artwork: String?
    var subtitle: String?
}

/// User preferences, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var provider: Provider {
        get { Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude }
        set { d.set(newValue.rawValue, forKey: "provider") }
    }

    func model(for p: Provider) -> String {
        d.string(forKey: "model.\(p.rawValue)") ?? p.models[0]
    }

    func setModel(_ m: String, for p: Provider) { d.set(m, forKey: "model.\(p.rawValue)") }

    var hotKey: HotKeyChoice {
        get {
            if let t = d.string(forKey: "hotkey.title"), d.object(forKey: "hotkey.code") != nil {
                return HotKeyChoice(title: t, keyCode: UInt32(d.integer(forKey: "hotkey.code")),
                                    carbonModifiers: UInt32(d.integer(forKey: "hotkey.mods")))
            }
            return HotKeyChoice.all.first { $0.title == d.string(forKey: "hotkey") } ?? .optionSpace
        }
        set {
            d.set(newValue.title, forKey: "hotkey.title")
            d.set(Int(newValue.keyCode), forKey: "hotkey.code")
            d.set(Int(newValue.carbonModifiers), forKey: "hotkey.mods")
        }
    }

    /// Pop the notch dashboard open when the pointer reaches the notch.
    var hoverToOpen: Bool {
        get { d.object(forKey: "hoverToOpen") as? Bool ?? true }
        set { d.set(newValue, forKey: "hoverToOpen") }
    }

    /// While music plays, the collapsed notch shows the spinning record beside it.
    var notchPeek: Bool {
        get { d.object(forKey: "notchPeek") as? Bool ?? true }
        set { d.set(newValue, forKey: "notchPeek") }
    }

    /// Spotify records play in the installed Spotify app (true) or the Spotify web player.
    var spotifyInApp: Bool {
        get { d.object(forKey: "spotifyInApp") as? Bool ?? true }
        set { d.set(newValue, forKey: "spotifyInApp") }
    }

    var favorites: [FavoritePlaylist] {
        get { d.data(forKey: "favorites").flatMap { try? JSONDecoder().decode([FavoritePlaylist].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "favorites") }
    }

    /// "System default", "Safari" or "Google Chrome". Used whenever an action names no browser.
    static let browsers = ["Safari", "Google Chrome", "System default"]
    var browser: String {
        get { d.string(forKey: "browser") ?? "Google Chrome" }
        set { d.set(newValue, forKey: "browser") }
    }

    /// Safari profile used when opening links in Safari (empty = whichever window is frontmost).
    var safariProfile: String {
        get { d.string(forKey: "safariProfile") ?? "" }
        set { d.set(newValue, forKey: "safariProfile") }
    }

    var geminiKey: String {
        get { d.string(forKey: "geminiKey") ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "" }
        set { d.set(newValue, forKey: "geminiKey") }
    }
}
