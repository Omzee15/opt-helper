import AppKit

/// Opens the notch dashboard when the pointer rests at the notch, and tucks it away once
/// the pointer leaves the island. Polls the pointer instead of using event monitors, so it
/// needs no Accessibility permission and also sees drags coming from other apps.
final class HoverTrigger {
    private let panel: LauncherPanel
    private var timer: Timer?
    private var enteredAt: Date?
    private var leftAt: Date?
    /// After a close, wait for the pointer to leave the hot zone before opening again.
    private var armed = true

    private let dwell: TimeInterval = 0.12
    private let grace: TimeInterval = 0.3

    init(panel: LauncherPanel) { self.panel = panel }

    func start() {
        guard timer == nil else { return }
        // Default run loop mode only: the timer pauses while a menu is tracking or while a
        // drag out of the shelf is in flight, so neither gets the island pulled from under it.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let open = panel.isVisible && panel.model.expanded

        if open {
            enteredAt = nil
            armed = false
            guard panel.model.mode == .dashboard, panel.model.openedByHover else { leftAt = nil; return }
            // Holding a button means a drag over the island; let the drop happen first.
            if panel.islandRect.insetBy(dx: -12, dy: -12).contains(p) || NSEvent.pressedMouseButtons != 0 {
                leftAt = nil
            } else if let l = leftAt {
                if Date().timeIntervalSince(l) > grace { panel.dismiss(); leftAt = nil; armed = false }
            } else {
                leftAt = Date()
            }
            return
        }

        leftAt = nil
        guard Settings.shared.hoverToOpen, let zone = Self.hotZone(at: p, leftExtra: panel.peekWing), zone.contains(p) else {
            enteredAt = nil
            armed = true
            return
        }
        guard armed else { return }
        if let e = enteredAt {
            if Date().timeIntervalSince(e) >= dwell {
                enteredAt = nil
                armed = false
                panel.present(.dashboard, byHover: true)
            }
        } else {
            enteredAt = Date()
        }
    }

    /// The notch plus a little slack on each side (and the peeking record), at the top edge of the pointer's screen.
    private static func hotZone(at p: NSPoint, leftExtra: CGFloat) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(p) }) else { return nil }
        let notch = NotchMetrics.notch(for: screen)
        let f = screen.frame
        let w = notch.width + 40
        return NSRect(x: f.midX - w / 2 - leftExtra, y: f.maxY - notch.height, width: w + leftExtra, height: notch.height + 2)
    }
}
