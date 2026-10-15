import AppKit
import ApplicationServices
import CoreServices
import SwiftUI

/// Everything OptHelper needs macOS to allow, asked for together on first launch so people
/// don't meet the prompts one at a time mid-task. Reopen from the menu bar: "Permissions…".
final class Permissions: ObservableObject {
    static let shared = Permissions()

    /// `noAnswer`: macOS didn't reply in time. Its check can hang inside a process,
    /// so every call is bounded and the flow moves on rather than waiting forever.
    enum State { case granted, denied, notAsked, unknown, noAnswer }

    struct Target: Identifiable {
        let name: String
        let bundleID: String
        let why: String
        var id: String { bundleID }
    }

    /// Apps OptHelper sends Apple Events to. Only installed ones are shown or asked about.
    static let automationTargets: [Target] = [
        Target(name: "System Events", bundleID: "com.apple.systemevents", why: "Opening links in a Safari profile"),
        Target(name: "Terminal", bundleID: "com.apple.Terminal", why: "Running your terminal shortcuts"),
    ] + MusicApp.all.map {
        Target(name: $0.name, bundleID: $0.bundleID,
               why: "Opening links, and showing and controlling YouTube Music or Spotify playing in a tab")
    } + [Target(name: "Spotify", bundleID: MusicApp.spotify.bundleID, why: "Showing what's playing, and playing your library records")]

    @Published private(set) var accessibility = false
    @Published private(set) var automation: [String: State] = [:]
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    private var cancelled = false

    var installedTargets: [Target] {
        Self.automationTargets.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    var allGranted: Bool {
        accessibility && installedTargets.allSatisfy { automation[$0.bundleID] == .granted }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        guard !busy else { return }
        let targets = installedTargets
        DispatchQueue.global(qos: .userInitiated).async {
            var states: [String: State] = [:]
            for t in targets { states[t.bundleID] = Self.automationState(t.bundleID, ask: false, timeout: 2) }
            DispatchQueue.main.async {
                guard !self.busy else { return }
                // A quick check that got no answer says nothing new; keep what we knew.
                for (id, s) in states where s != .noAnswer && s != .unknown || self.automation[id] == nil {
                    self.automation[id] = s
                }
            }
        }
    }

    /// Asks for every permission not yet granted. macOS only asks about apps that are running,
    /// so apps that aren't are opened hidden for the question and quit again afterwards.
    func requestAll() {
        guard !busy else { return }
        busy = true
        cancelled = false
        let targets = installedTargets.filter { automation[$0.bundleID] != .granted }
        DispatchQueue.global(qos: .userInitiated).async {
            for t in targets {
                if self.cancelled { break }
                DispatchQueue.main.async { self.progress = "Opening \(t.name) in the background…" }
                let launched = Self.ensureRunning(t.bundleID)
                if self.cancelled { if launched { Self.quit(t.bundleID) }; break }
                DispatchQueue.main.async { self.progress = "Waiting for you to answer about \(t.name)…" }
                // Long enough to read and answer the dialog; past that, move on to the next app.
                let s = Self.automationState(t.bundleID, ask: true, timeout: 60)
                if launched { Self.quit(t.bundleID) }
                DispatchQueue.main.async { self.automation[t.bundleID] = s }
            }
            DispatchQueue.main.async {
                let stopped = self.cancelled
                self.progress = ""
                self.busy = false
                // Last, since it sends people to System Settings to flip a switch.
                if !stopped && !AXIsProcessTrusted() {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    self.accessibility = AXIsProcessTrustedWithOptions(opts)
                }
            }
        }
    }

    /// Stops after the current app; a dialog already on screen stays until answered.
    func stop() {
        cancelled = true
        progress = "Stopping…"
    }

    func openPrivacySettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    // MARK: Internals

    private static let lock = NSLock()
    /// Targets whose check hasn't returned yet. One may never return, so it isn't asked again
    /// while it's outstanding, rather than piling up stuck threads.
    private static var inFlight: Set<String> = []

    /// Runs macOS's check on its own thread and waits at most `timeout` seconds.
    /// With `ask`, macOS shows its consent dialog and the check returns once it's answered.
    private static func automationState(_ bundleID: String, ask: Bool, timeout: TimeInterval) -> State {
        lock.lock()
        if inFlight.contains(bundleID) { lock.unlock(); return .noAnswer }
        inFlight.insert(bundleID)
        lock.unlock()

        let done = DispatchSemaphore(value: 0)
        var result = State.noAnswer
        Thread.detachNewThread {
            let s = rawState(bundleID, ask: ask)
            lock.lock(); result = s; inFlight.remove(bundleID); lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return result
    }

    private static func rawState(_ bundleID: String, ask: Bool) -> State {
        var addr = AEAddressDesc()
        let made = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &addr) }
        guard made == noErr else { return .unknown }
        defer { AEDisposeDesc(&addr) }
        switch AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown  // e.g. the app isn't running, so macOS won't say
        }
    }

    /// Opens the app in the background if needed and waits for it to finish launching;
    /// true if we opened it.
    private static func ensureRunning(_ bundleID: String) -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return false }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in opened.signal() }
        _ = opened.wait(timeout: .now() + 15)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: \.isFinishedLaunching) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 1)  // let it start taking Apple Events
        return true
    }

    private static func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }
}

struct PermissionsView: View {
    @ObservedObject var perms = Permissions.shared
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let OptHelper work with your apps").font(.title2.weight(.semibold))
            Text("Grant everything once now and you won't be asked again while you work. macOS shows a prompt for each app; apps that aren't open are started in the background for a moment and closed again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    row("Accessibility", "Clicking Safari's “New Profile Window” menu", perms.accessibility ? .granted : .notAsked)
                    ForEach(perms.installedTargets) { t in
                        Divider()
                        row(t.name, t.why, perms.automation[t.bundleID] ?? .unknown)
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .frame(maxHeight: 320)

            Text("For music playing in a browser tab, also turn on Develop › Allow JavaScript from Apple Events (Safari) or View › Developer › Allow JavaScript from Apple Events (Chrome-based browsers).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                if perms.busy { ProgressView().controlSize(.small); Text(perms.progress).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if perms.automation.values.contains(.denied) {
                    Button("Open Automation Settings") { perms.openPrivacySettings("Privacy_Automation") }
                }
                if !perms.accessibility {
                    Button("Open Accessibility Settings") { perms.openPrivacySettings("Privacy_Accessibility") }
                }
                Button(perms.allGranted ? "Done" : "Later") { onDone() }
                if perms.busy {
                    Button("Stop") { perms.stop() }
                } else if !perms.allGranted {
                    Button("Grant All") { perms.requestAll() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { perms.refresh() }
        // Accessibility is switched on in System Settings, so keep checking while open.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in perms.refresh() }
    }

    private func row(_ title: String, _ detail: String, _ s: Permissions.State) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(s)).foregroundStyle(color(s)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(label(s)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }

    private func icon(_ s: Permissions.State) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notAsked, .unknown: return "circle"
        case .noAnswer: return "exclamationmark.circle"
        }
    }

    private func color(_ s: Permissions.State) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notAsked, .unknown: return .secondary
        case .noAnswer: return .orange
        }
    }

    private func label(_ s: Permissions.State) -> String {
        switch s {
        case .granted: return "Allowed"
        case .denied: return "Denied — allow in Settings"
        case .notAsked: return "Not yet asked"
        case .unknown: return "Not yet asked"
        case .noAnswer: return "No answer — press Grant All again"
        }
    }
}

final class PermissionsWindow {
    private var window: NSWindow?
    private static let shownKey = "permissionsOnboardingShown"

    /// First launch only, so people who chose "Later" aren't nagged; the menu bar item reopens it.
    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        show()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PermissionsView { [weak self] in self?.window?.close() }))
            w.title = "OptHelper Permissions"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
