import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global shortcuts via Carbon's `RegisterEventHotKey`.
///
/// Deliberately *not* `NSEvent.addGlobalMonitorForEvents`: monitoring keystrokes
/// that way requires the user to grant Accessibility access, and keeping this
/// app permission-free is the point of it. `RegisterEventHotKey` needs nothing.
final class HotKeyManager: ObservableObject {

    struct Spec {
        let id: UInt32
        let name: String
        let keyCode: UInt32
        let modifiers: UInt32
        let display: String
    }

    /// ⌃⌥⌘ is used throughout: plainer combinations collide with system
    /// defaults (⌃Space and ⌃⌥Space are input-source switching) or with
    /// whatever app is in front, and a global hotkey wins over both.
    static let specs: [Spec] = [
        Spec(id: 1, name: "Start / pause", keyCode: UInt32(kVK_ANSI_P),
             modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘P"),
        Spec(id: 2, name: "Skip to next",  keyCode: UInt32(kVK_ANSI_K),
             modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘K"),
        Spec(id: 3, name: "Restart phase", keyCode: UInt32(kVK_ANSI_R),
             modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘R"),
    ]

    /// Which specs actually got the key combination. Registration fails if
    /// another app already owns it, and silently doing nothing would be worse
    /// than saying so in Settings.
    @Published private(set) var registered: Set<UInt32> = []

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private let signature: OSType = 0x504F4D4F   // 'POMO'

    func enable(_ actions: [UInt32: () -> Void]) {
        disable()
        self.actions = actions
        installHandler()

        for spec in Self.specs where actions[spec.id] != nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: spec.id)
            let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr {
                refs.append(ref)
                registered.insert(spec.id)
            }
        }
    }

    func disable() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        refs.removeAll()
        registered.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        actions.removeAll()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                Unmanaged<HotKeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .fire(id.id)
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    private func fire(_ id: UInt32) {
        DispatchQueue.main.async { [weak self] in self?.actions[id]?() }
    }

    deinit { disable() }
}
