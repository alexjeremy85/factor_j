import Carbon.HIToolbox
import Foundation

/// Atalho de teclado global (funciona com o app em segundo plano).
/// Implementado com RegisterEventHotKey (Carbon) — sem dependências externas
/// e sem exigir permissão de acessibilidade.
final class HotKeyManager {
    struct Preset: Identifiable, Equatable {
        let id: String
        let label: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Presets oferecidos em Ajustes (evita UI de captura de tecla na v1).
    static let presets: [Preset] = [
        Preset(id: "opt-cmd-r", label: "⌥⌘R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey)),
        Preset(id: "ctrl-opt-r", label: "⌃⌥R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey)),
        Preset(id: "shift-cmd-9", label: "⇧⌘9", keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(shiftKey | cmdKey)),
        Preset(id: "opt-cmd-g", label: "⌥⌘G", keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey | cmdKey)),
    ]

    static func preset(id: String) -> Preset {
        presets.first { $0.id == id } ?? presets[0]
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    func register(preset: Preset, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { manager.handler?() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x464A_4B31), id: 1)  // "FJK1"
        RegisterEventHotKey(
            preset.keyCode,
            preset.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    deinit {
        unregister()
    }
}
