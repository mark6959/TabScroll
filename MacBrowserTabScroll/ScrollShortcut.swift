import AppKit
import CoreGraphics
import SwiftUI

struct ScrollShortcut: Codable {
    struct Key: Codable {
        let code: UInt16
        let name: String
    }

    private static let supportedModifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]

    static let standard = Self(keys: [], modifiers: [.maskControl, .maskShift])

    let keys: [Key]
    private let modifierMask: UInt64

    init(keys: [Key], modifiers: CGEventFlags) {
        self.keys = keys
        modifierMask = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    var isEmpty: Bool { keys.isEmpty && modifierMask == 0 }

    var label: String {
        let flags = CGEventFlags(rawValue: modifierMask)
        let modifiers: [(CGEventFlags, String)] = [
            (.maskControl, "Control"), (.maskShift, "Shift"), (.maskAlternate, "Option"), (.maskCommand, "Command")
        ]
        let names = modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil }
        return (names + keys.map(\.name)).joined(separator: " + ")
    }

    func matchesKeyDown(_ event: CGEvent) -> Bool {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        return keys.contains { $0.code == code }
            && event.flags.intersection(Self.supportedModifiers).rawValue == modifierMask
            && keys.allSatisfy { $0.code == code || CGEventSource.keyState(.combinedSessionState, key: $0.code) }
    }

    func isHeld(for event: CGEvent) -> Bool {
        !isEmpty && event.flags.intersection(Self.supportedModifiers).rawValue == modifierMask
            && areKeysHeld
    }

    func isHeld(togetherWith other: Self, for event: CGEvent) -> Bool {
        let combinedMask = modifierMask | other.modifierMask
        return !isEmpty && !other.isEmpty
            && event.flags.intersection(Self.supportedModifiers).rawValue == combinedMask
            && areKeysHeld && other.areKeysHeld
    }

    private var areKeysHeld: Bool {
        keys.allSatisfy { CGEventSource.keyState(.combinedSessionState, key: $0.code) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var onCapture: (ScrollShortcut) -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onCapture: onCapture)
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
    }

    final class CaptureView: NSView {
        var onCapture: (ScrollShortcut) -> Void
        private var heldKeys: [ScrollShortcut.Key] = []
        private var modifiers: CGEventFlags = []

        init(onCapture: @escaping (ScrollShortcut) -> Void) {
            self.onCapture = onCapture
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            heldKeys.removeAll { !CGEventSource.keyState(.combinedSessionState, key: $0.code) }
            guard !heldKeys.contains(where: { $0.code == event.keyCode }) else { return }
            heldKeys.append(.init(code: event.keyCode, name: keyName(event)))
            modifiers = event.cgEvent?.flags ?? []
            capture()
        }

        override func keyUp(with event: NSEvent) {
            heldKeys.removeAll { $0.code == event.keyCode }
        }

        override func flagsChanged(with event: NSEvent) {
            let oldModifiers = modifiers
            let supported: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
            modifiers = (event.cgEvent?.flags ?? []).intersection(supported)
            if !modifiers.subtracting(oldModifiers).isEmpty { capture() }
        }

        private func capture() {
            let shortcut = ScrollShortcut(keys: heldKeys, modifiers: modifiers)
            if !shortcut.isEmpty { onCapture(shortcut) }
        }

        private func keyName(_ event: NSEvent) -> String {
            switch event.keyCode {
            case 36: return "Return"
            case 48: return "Tab"
            case 49: return "Space"
            case 51: return "Delete"
            case 53: return "Escape"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default:
                let characters = event.charactersIgnoringModifiers ?? ""
                if let scalar = characters.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) {
                    return "F\(scalar.value - 0xF704 + 1)"
                }
                return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
            }
        }
    }
}
