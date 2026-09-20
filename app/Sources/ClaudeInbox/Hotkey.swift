import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A global shortcut, so the panel opens from wherever the hands already are.
///
/// Carbon's `RegisterEventHotKey` rather than an event monitor on purpose: a
/// monitor needs Accessibility permission, which is a system dialog and a trust
/// prompt for something that only wants one key combination. This needs neither.
@MainActor
final class Hotkey {
    static let shared = Hotkey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// ⌥Space. Left alone by macOS and by the shells people live in, which is
    /// more than can be said for most combinations worth pressing.
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(optionKey),
                  action: @escaping () -> Void) {
        unregister()
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                Task { @MainActor in Hotkey.shared.fire() }
                return noErr
            },
            1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x434C4249), id: 1)  // 'CLBI'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    fileprivate func fire() { action?() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

/// Starting with the machine.
///
/// A menu bar app that is not running when a session blocks is an app that never
/// tells you anything — and the bridge, finding no heartbeat, stops waiting for
/// it at all. So this is not a convenience toggle; it is most of whether the
/// product works.
enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                // Already registered is not a failure, it is the desired state.
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
