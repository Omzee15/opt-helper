import AppKit
import Carbon.HIToolbox
import SwiftUI

extension HotKeyChoice {
    /// A shortcut from a key press, or nil if it has no ⌘/⌥/⌃ (a bare key would hijack typing).
    init?(event e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0, title = ""
        if f.contains(.control) { mods |= UInt32(controlKey); title += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); title += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); title += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); title += "⌘" }
        let names: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        guard let key = names[e.keyCode] ?? e.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(title: title + " " + key, keyCode: UInt32(e.keyCode), carbonModifiers: mods)
    }
}

/// Captures the next key press as the global shortcut.
final class ShortcutRecorder: ObservableObject {
    @Published var recording = false
    @Published var title = Settings.shared.hotKey.title
    @Published var error: String?
    private var monitor: Any?
    /// Swaps the global hotkey; returns false if another app owns the combination.
    var apply: ((HotKeyChoice) -> Bool)?
    var suspend: (() -> Void)?

    func toggle() { recording ? finish(nil) : begin() }

    private func begin() {
        error = nil
        recording = true
        suspend?()  // otherwise pressing the current shortcut would fire it instead of recording it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.finish(nil); return nil }
            if let c = HotKeyChoice(event: e) { self.finish(c) } else { self.error = "Include ⌘, ⌥ or ⌃" }
            return nil
        }
    }

    func finish(_ choice: HotKeyChoice?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        let target = choice ?? Settings.shared.hotKey
        if apply?(target) == true {
            Settings.shared.hotKey = target
            error = nil
        } else {
            _ = apply?(Settings.shared.hotKey)
            error = "\(target.title) is used by another app or macOS"
        }
        title = Settings.shared.hotKey.title
    }
}

struct PreferencesView: View {
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject private var favorites = Favorites.shared
    @State private var hover = Settings.shared.hoverToOpen

    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Open when the pointer reaches the notch", isOn: $hover)
                    .onChange(of: hover) { Settings.shared.hoverToOpen = $0 }
                LabeledContent("Shelf folder") {
                    Button("Show in Finder") { Shelf.shared.revealFolder() }
                }
            }

            Section {
                LabeledContent("Open launcher") {
                    HStack {
                        Button(recorder.recording ? "Press a shortcut… (Esc cancels)" : recorder.title) { recorder.toggle() }
                            .frame(minWidth: 120)
                        Button("Reset") { recorder.finish(.optionSpace) }
                            .disabled(recorder.title == HotKeyChoice.optionSpace.title)
                    }
                }
                if let e = recorder.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("For ⌘ Space, first turn off Spotlight's shortcut in System Settings → Keyboard → Keyboard Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($favorites.items) { $f in
                    // Grouped forms turn a TextField's title into a row label and squeeze the
                    // field itself; hide labels so each field gets a real, editable box.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Name", text: $f.name, prompt: Text("Name"))
                            Picker("Source", selection: $f.source) {
                                ForEach(FavoritePlaylist.Source.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .frame(width: 130)
                            Button { favorites.items.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                        TextField("Link", text: $f.value, prompt: Text(f.source.hint))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 2)
                }
                Button {
                    favorites.items.append(FavoritePlaylist(name: "", source: .spotify, value: ""))
                } label: { Label("Add playlist", systemImage: "plus") }
            } header: {
                Text("Favorite playlists")
            } footer: {
                Text("Shown on the notch dashboard. Apple Music plays a playlist from your library by name; Spotify takes a playlist link or URI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .frame(minHeight: 460)
    }
}

final class PreferencesWindow {
    private var window: NSWindow?
    let recorder = ShortcutRecorder()

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(recorder: recorder)))
            w.title = "OptHelper Preferences"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        recorder.title = Settings.shared.hotKey.title
        // Opened from the non-activating notch, the app may not be frontmost yet; without
        // activation, typing would keep going to whichever app was.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
