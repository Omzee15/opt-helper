import AppKit
import SwiftUI

/// The search field (hotkey) or the music + shelf dashboard (hover).
enum NotchMode {
    case launcher, dashboard
    var width: CGFloat { self == .launcher ? 640 : 720 }
}

final class LauncherModel: ObservableObject {
    @Published var mode: NotchMode = .launcher
    @Published var text = ""
    @Published var status = ""
    @Published var isError = false
    @Published var busy = false
    /// Grown out of the notch (true) or tucked back into it (false).
    @Published var expanded = false
    /// Size of the hardware notch, or a menu-bar-sized stand-in on screens without one.
    @Published var notch = CGSize(width: 190, height: 32)
    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearch: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Height of the island below the notch, reported by the view (for hover hit-testing).
    var contentHeight: CGFloat = 0
    /// Hover-opened islands close when the pointer leaves; others when they lose focus.
    var openedByHover = false
}

enum NotchMetrics {
    static let maxWidth: CGFloat = 720   // widest body of any mode
    static let flare: CGFloat = 14       // concave top corners that blend into the screen edge
    static let corner: CGFloat = 24      // bottom corner radius when expanded
    static let maxContent: CGFloat = 180 // room below the notch for the tallest mode
    static let shadowPad: CGFloat = 36

    static func notch(for screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 190, height: max(bar, NSStatusBar.system.thickness))
    }
}

/// A notch silhouette: flat top flush with the screen edge, concave flares at the top
/// corners, rounded bottom corners. Corners animate so it can morph out of the real notch.
struct NotchShape: Shape {
    var flare: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, corner) }
        set { flare = newValue.first; corner = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = min(corner, rect.height / 2, (rect.width - 2 * flare) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                       control: CGPoint(x: rect.minX + flare, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - c))
        p.addQuadCurve(to: CGPoint(x: rect.minX + flare + c, y: rect.maxY),
                       control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - flare - c, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - c),
                       control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 60

    var body: some View {
        let open = model.expanded
        let flare = open ? NotchMetrics.flare : 6
        let shape = NotchShape(flare: flare, corner: open ? NotchMetrics.corner : 10)
        let width = (open ? model.mode.width : model.notch.width) + 2 * flare
        let height = model.notch.height + (open ? contentHeight : 0)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            Group {
                if model.mode == .dashboard {
                    DashboardHeader(model: model)
                    measured(DashboardView(model: model)).padding(.top, model.notch.height)
                } else {
                    measured(content).padding(.top, model.notch.height)
                }
            }
            .frame(width: model.mode.width, alignment: .top)
            .opacity(open ? 1 : 0)
            .scaleEffect(open ? 1 : 0.85, anchor: .top)
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: open)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: contentHeight)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.36, dampingFraction: 0.85), value: model.mode)
        .onChange(of: open) { focused = $0 && model.mode == .launcher }
        .onChange(of: model.mode) { m in
            DispatchQueue.main.async { focused = open && m == .launcher }
        }
    }

    private func measured<V: View>(_ v: V) -> some View {
        v.frame(width: model.mode.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            .onPreferenceChange(HeightKey.self) { contentHeight = $0; model.contentHeight = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                TextField("Open anything…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .disabled(model.busy)
                    .onSubmit { model.onSubmit?(model.text) }
                    .onExitCommand { model.onDismiss?() }
                if model.busy { ProgressView().controlSize(.small) }
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 13))
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
    }
}

final class LauncherPanel: NSPanel {
    let model = LauncherModel()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar so the island can hang from the very top edge of the screen.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the SwiftUI shape draws its own; a window shadow would outline the empty frame
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = NotchHostingView(rootView: LauncherView(model: model))
    }

    override var canBecomeKey: Bool { true }

    /// Keep AppKit from pushing the window down below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The visible island in screen coordinates.
    var islandRect: NSRect {
        let w = model.mode.width + 2 * NotchMetrics.flare
        let h = model.notch.height + model.contentHeight
        return NSRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
    }

    /// Typing on the dashboard turns it into the launcher, starting with what was typed.
    /// Keys that land before the text field has taken focus are appended rather than lost.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isVisible, model.expanded, let typed = Self.typedText(event) {
            if model.mode == .dashboard {
                model.text = typed
                present(.launcher)
                moveCaretToEnd()
                return
            }
            if !(firstResponder is NSTextView) {
                model.text += typed
                moveCaretToEnd()
                return
            }
        }
        super.sendEvent(event)
    }

    /// Printable input only: no ⌘/⌃ shortcuts, Return, Tab, Escape, arrows or function keys.
    private static func typedText(_ e: NSEvent) -> String? {
        guard e.modifierFlags.intersection([.command, .control]).isEmpty,
              let c = e.characters, !c.isEmpty,
              c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return c
    }

    /// Focusing the field can select its contents; put the caret after the typed text instead.
    private func moveCaretToEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tv = self.firstResponder as? NSTextView else { return }
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
    }

    /// Escape closes the dashboard (the launcher's text field handles its own).
    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// ⌘V on the dashboard pastes into the shelf.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if model.mode == .dashboard, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v" {
            Shelf.shared.paste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The launcher activates the app; a hover-opened dashboard only takes key focus.
    func present(_ mode: NotchMode = .launcher, byHover: Bool = false) {
        if isVisible && model.expanded {
            model.mode = mode
            if mode == .launcher { NSApp.activate(ignoringOtherApps: true); makeKey() }
            mode == .dashboard ? NowPlaying.shared.start() : NowPlaying.shared.stop()
            return
        }
        model.mode = mode
        model.openedByHover = byHover
        model.text = ""
        model.status = ""
        model.isError = false
        model.busy = false
        model.expanded = false

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        model.notch = NotchMetrics.notch(for: screen)
        let w = NotchMetrics.maxWidth + 2 * NotchMetrics.flare + 2 * NotchMetrics.shadowPad
        let h = model.notch.height + NotchMetrics.maxContent + NotchMetrics.shadowPad
        let f = screen.frame
        setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)

        mode == .dashboard ? NowPlaying.shared.start() : NowPlaying.shared.stop()
        if byHover {
            // Key without activating the app: keystrokes reach the island (so typing starts
            // a search) while the app you were in stays frontmost.
            makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        // Next runloop pass, so the island visibly grows out of the notch instead of popping in.
        DispatchQueue.main.async { self.model.expanded = true }
    }

    /// Re-open after an error, in case the panel already started retracting.
    func reveal() {
        model.expanded = true
        makeKeyAndOrderFront(nil)
    }

    /// Retract into the notch, then hide.
    func dismiss() {
        guard isVisible else { return }
        model.expanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.orderOut(nil)
            NowPlaying.shared.stop()
        }
    }
}

/// Hosts the island and makes all of it a drop target for the shelf, so a file can be
/// dropped on the notch itself rather than only on the shelf box. Drops are always copies.
/// Also starts drags out of the shelf, again offering copies only, so the shelf keeps its item.
final class NotchHostingView: NSHostingView<LauncherView> {
    private let copySource = CopyOnlyDragSource()
    private var pressedItem: URL?
    private var pressPoint: NSPoint = .zero

    required init(rootView: LauncherView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    private var panel: LauncherPanel? { window as? LauncherPanel }

    // MARK: Dropping in

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        guard info.draggingSource as AnyObject? !== copySource, let panel else { return false }
        let p = panel.convertPoint(toScreen: info.draggingLocation)
        return panel.islandRect.insetBy(dx: -12, dy: -12).contains(p)
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(info)
        if ok, let panel, panel.model.mode != .dashboard || !panel.model.expanded {
            panel.present(.dashboard, byHover: true)
        }
        if Shelf.shared.dropTargeted != ok { Shelf.shared.dropTargeted = ok }
        return ok ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { Shelf.shared.dropTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { Shelf.shared.dropTargeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Shelf.shared.dropTargeted = false
        return Shelf.shared.paste(from: sender.draggingPasteboard)
    }

    // MARK: Dragging out

    /// SwiftUI's coordinates for the island, top-left origin.
    private func swiftUIPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        let p = swiftUIPoint(event)
        let shelf = Shelf.shared
        pressedItem = shelf.boxFrame.contains(p) ? shelf.itemFrames.first { $0.value.contains(p) && shelf.items.contains($0.key) }?.key : nil
        pressPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = pressedItem else { return super.mouseDragged(with: event) }
        let d = hypot(event.locationInWindow.x - pressPoint.x, event.locationInWindow.y - pressPoint.y)
        guard d > 3 else { return }
        pressedItem = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let at = convert(pressPoint, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 20, y: at.y - 20, width: 40, height: 40), contents: icon)
        beginDraggingSession(with: [item], event: event, source: copySource)
    }

    override func mouseUp(with event: NSEvent) {
        pressedItem = nil
        super.mouseUp(with: event)
    }
}

/// Drags out of the shelf offer only a copy, so Finder never moves the file out of it.
private final class CopyOnlyDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
