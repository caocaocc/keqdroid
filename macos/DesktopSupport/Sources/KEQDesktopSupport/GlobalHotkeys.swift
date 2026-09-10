import AppKit
import Carbon

public struct HotkeyCombination: Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init?(token: String) {
        let pieces = token.split(separator: "+").map(String.init)
        guard let key = pieces.last, let code = Self.codes[key] else { return nil }
        let flags: [String: UInt32] = ["ctrl": UInt32(controlKey), "alt": UInt32(optionKey),
                                       "shift": UInt32(shiftKey), "meta": UInt32(cmdKey)]
        var modifiers: UInt32 = 0
        for modifier in pieces.dropLast() {
            guard let value = flags[modifier] else { return nil }
            modifiers |= value
        }
        guard modifiers != 0 || (key.first == "f" && Int(key.dropFirst()) != nil) else { return nil }
        self.keyCode = code
        self.modifiers = modifiers
    }

    private static let codes: [String: UInt32] = [
        "keyA":0, "keyS":1, "keyD":2, "keyF":3, "keyH":4, "keyG":5,
        "keyZ":6, "keyX":7, "keyC":8, "keyV":9, "keyB":11, "keyQ":12,
        "keyW":13, "keyE":14, "keyR":15, "keyY":16, "keyT":17,
        "digit1":18, "digit2":19, "digit3":20, "digit4":21, "digit6":22,
        "digit5":23, "equal":24, "digit9":25, "digit7":26, "minus":27,
        "digit8":28, "digit0":29, "bracketRight":30, "keyO":31, "keyU":32,
        "bracketLeft":33, "keyI":34, "keyP":35, "keyL":37, "keyJ":38,
        "quote":39, "keyK":40, "semicolon":41, "backslash":42, "comma":43,
        "slash":44, "keyN":45, "keyM":46, "period":47, "space":49, "backquote":50,
        "f1":122, "f2":120, "f3":99, "f4":118, "f5":96, "f6":97,
        "f7":98, "f8":100, "f9":101, "f10":109, "f11":103, "f12":111,
        "insert":114, "home":115, "pageUp":116, "delete":117, "end":119,
        "pageDown":121, "arrowLeft":123, "arrowRight":124, "arrowDown":125, "arrowUp":126
    ]
}

final class GlobalHotkeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    var onPressed: ((String) -> Void)?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            var hotkey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
            guard status == noErr, let action = owner.actions[hotkey.id] else { return OSStatus(eventNotHandledErr) }
            owner.onPressed?(action)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func apply(_ bindings: [[String: Any]]) -> [String] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        var failures: [String] = []
        for (index, binding) in bindings.enumerated() {
            guard let action = binding["action"] as? String else { continue }
            guard let token = binding["binding"] as? String,
                  let combination = HotkeyCombination(token: token) else {
                failures.append(action); continue
            }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combination.keyCode, combination.modifiers,
                EventHotKeyID(signature: 0x4b455144, id: id), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else { failures.append(action) }
        }
        return failures
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
