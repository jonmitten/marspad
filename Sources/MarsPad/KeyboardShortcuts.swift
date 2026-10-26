import SwiftUI
import AppKit

enum PadShortcut: Equatable {
    case assign, clear, preview, previewPad, stop, undo, redo
    case sample(Int), pad(Int, Int), bank(Int)
    static func action(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editing: Bool) -> PadShortcut? {
        guard !editing else { return nil }
        if characters.lowercased() == "z", modifiers.contains(.command), modifiers.intersection([.control, .option]).isEmpty {
            return modifiers.contains(.shift) ? .redo : .undo
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        if !modifiers.contains(.shift) {
            switch keyCode {
            case 123: return .pad(-1, 0)
            case 124: return .pad(1, 0)
            case 125: return .pad(0, -1)
            case 126: return .pad(0, 1)
            default: break
            }
        }
        let key = characters.lowercased()
        if let number = Int(key), (1...8).contains(number), key.count == 1 { return .bank(number - 1) }
        switch key {
        case "w": return .sample(-1)
        case "s": return .sample(1)
        case "d": return .preview
        case "f": return .previewPad
        case "a": return .stop
        case "c": return .clear
        case " ": return .assign
        default: return nil
        }
    }
}

struct PadKeyboardShortcuts: NSViewRepresentable {
    var action: (PadShortcut) -> Void
    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) { view.action = action }
    final class ShortcutView: NSView {
        var action: ((PadShortcut) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                let responder = window.firstResponder
                let editing = responder is NSTextView || responder is NSTextField
                guard let shortcut = PadShortcut.action(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags, editing: editing) else { return event }
                self.action?(shortcut)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
