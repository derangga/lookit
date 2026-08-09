// R = HotkeyRegistrar.
//
// Carbon's RegisterEventHotKey rather than an event tap, because it needs no
// Accessibility permission — verified: lookit requires no TCC grant at all.

import Carbon.HIToolbox
import Foundation

@MainActor
public struct HotkeyRegistrar {
    /// Returns false when the system refuses the combination, which usually
    /// means something else already owns it.
    public var register: (Keybinding, @escaping () -> Void) -> Bool
    public var unregisterAll: () -> Void

    public init(
        register: @escaping (Keybinding, @escaping () -> Void) -> Bool,
        unregisterAll: @escaping () -> Void
    ) {
        self.register = register
        self.unregisterAll = unregisterAll
    }
}

extension HotkeyRegistrar {
    public static var live: HotkeyRegistrar {
        HotkeyRegistrar(
            register: { HotkeyCenter.shared.register($0, action: $1) },
            unregisterAll: { HotkeyCenter.shared.unregisterAll() }
        )
    }
}

// MARK: - Carbon

@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    public func register(_ binding: Keybinding, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            EventHotKeyID(signature: hotkeySignature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return false }

        nextID += 1
        actions[id] = action
        refs[id] = ref
        return true
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), hotkeyHandler, 1, &spec, nil, nil)
    }
}

private let hotkeySignature = OSType(0x6C_6B_69_74)  // 'lkit'

// A C callback cannot capture, so it routes through the shared centre. Carbon
// dispatches on the main run loop, which is what makes assumeIsolated sound.
private let hotkeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == hotkeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    MainActor.assumeIsolated { HotkeyCenter.shared.fire(id.id) }
    return noErr
}

// MARK: - Installing the configured bindings

public enum HotkeyAction: String, Sendable, CaseIterable {
    case zoomIn
    case zoomOut
    case reset
}

/// Register the configured hotkeys, replacing any already installed.
///
/// Every failure is individual: a binding that will not parse, and a binding the
/// system refuses, both drop just themselves. One bad hotkey must never take the
/// other two down — that is the difference between a warning in the HUD and an
/// app that silently does nothing.
@MainActor
public func installHotkeys(
    _ keys: Config.Keys,
    registrar: HotkeyRegistrar,
    perform: @escaping (HotkeyAction) -> Void
) -> [ConfigWarning] {
    registrar.unregisterAll()

    let parsed = keybindings(from: keys)
    var warnings = parsed.warnings

    let bindings: [(HotkeyAction, Keybinding?, String)] = [
        (.zoomIn, parsed.zoomIn, keys.zoomIn),
        (.zoomOut, parsed.zoomOut, keys.zoomOut),
        (.reset, parsed.reset, keys.reset),
    ]

    for (action, binding, text) in bindings {
        guard let binding else { continue }  // already warned about by keybindings(from:)

        if !registrar.register(binding, { perform(action) }) {
            warnings.append(
                ConfigWarning(
                    key: "keys.\(action.rawValue)",
                    detail: "the system refused \"\(text)\" — another app probably owns it"
                )
            )
        }
    }

    return warnings
}

// MARK: - Test double

/// Records what was registered, and can fire bindings on demand. Swapping this
/// in is how the hotkey wiring is checked without a running event loop.
@MainActor
public final class RecordedHotkeys {
    public private(set) var registered: [Keybinding] = []
    public private(set) var unregisterCount = 0
    public private(set) var fired: [HotkeyAction] = []

    private var actions: [() -> Void] = []
    private let refuse: Set<UInt32>

    /// - Parameter refusing: key codes the fake system will reject, standing in
    ///   for a combination another app already owns.
    public init(refusing: Set<UInt32> = []) {
        refuse = refusing
    }

    public var registrar: HotkeyRegistrar {
        HotkeyRegistrar(
            register: { [weak self] binding, action in
                guard let self else { return false }
                if refuse.contains(binding.keyCode) { return false }
                registered.append(binding)
                actions.append(action)
                return true
            },
            unregisterAll: { [weak self] in
                guard let self else { return }
                unregisterCount += 1
                registered.removeAll()
                actions.removeAll()
            }
        )
    }

    public func record(_ action: HotkeyAction) { fired.append(action) }

    public func fire(_ index: Int) {
        guard actions.indices.contains(index) else { return }
        actions[index]()
    }
}
