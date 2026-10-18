import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide keyboard shortcuts through Carbon's RegisterEventHotKey, which
/// needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, hotKey: HotKey?, handler: @escaping () -> Void) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        guard let hotKey else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_4D42), id: id) // 'PLMB'
        if RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func make(from event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        let key = specialKeyNames[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: carbon, display: display + key)
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Click, then press a key combination with ⌘, ⌃ or ⌥. Esc cancels, ⌫ clears.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: TE.s1) {
            Button(recording ? "type shortcut…" : (hotKey?.display ?? "record")) {
                recording ? stop() : begin()
            }
            .teButton(recording ? .primary : .secondary)
            .frame(minWidth: 120, alignment: .trailing)
            if hotKey != nil, !recording {
                Button("clear") { hotKey = nil; onChange() }
                    .teButton(.text)
                    .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func begin() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete: hotKey = nil; stop(); onChange()
            default:
                guard let new = HotKeyCenter.make(from: event) else { NSSound.beep(); return nil }
                hotKey = new
                stop()
                onChange()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
