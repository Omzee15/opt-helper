import Carbon.HIToolbox

/// Global hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            Unmanaged<HotKey>.fromOpaque(ctx!).takeUnretainedValue().callback()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
    }

    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4F505448), id: 1) // 'OPTH'
        return RegisterEventHotKey(choice.keyCode, choice.carbonModifiers, id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
