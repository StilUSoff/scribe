import Carbon.HIToolbox

/// Глобальная горячая клавиша через Carbon RegisterEventHotKey: не требует «Универсального доступа»
/// и продолжает работать, когда другое приложение включает Secure Input (поле пароля и т.п.).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// ⌥Space по умолчанию. Возвращает false, если сочетание уже занято (например, запущен Handy).
    @discardableResult
    func register(keyCode: Int = kVK_Space, modifiers: Int = optionKey, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action?() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        let id = EventHotKeyID(signature: OSType(0x5343_5242), id: 1)  // 'SCRB'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }

    deinit { unregister() }
}
