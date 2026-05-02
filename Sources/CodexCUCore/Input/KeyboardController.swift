import CoreGraphics
import Foundation

public struct KeyboardController: Sendable {
    private let parser = KeySyntaxParser()

    public init() {}

    /// Type a string of text using CGEvent keyboard unicode, optionally targeting a specific process
    public func typeText(_ text: String, targetPID: pid_t? = nil) throws {
        let maxUTF16Units = 15
        let utf16 = Array(text.utf16)
        var utf16Offset = 0

        while utf16Offset < utf16.count {
            let remaining = utf16.count - utf16Offset
            let chunkLen = min(remaining, maxUTF16Units)
            let chars = Array(utf16[utf16Offset..<(utf16Offset + chunkLen)])

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw InputError.eventCreationFailed
            }
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            postEvent(keyDown, to: targetPID)

            guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw InputError.eventCreationFailed
            }
            postEvent(keyUp, to: targetPID)

            utf16Offset += chunkLen

            if utf16Offset < utf16.count {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// Press a key combination using xdotool syntax, optionally targeting a specific process
    /// Examples: "super+c", "Return", "ctrl+shift+a", "Tab"
    public func pressKey(_ spec: String, targetPID: pid_t? = nil) throws {
        let parsed = try parser.parse(spec)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true) else {
            throw InputError.eventCreationFailed
        }
        keyDown.flags = parsed.modifiers
        postEvent(keyDown, to: targetPID)

        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
            throw InputError.eventCreationFailed
        }
        keyUp.flags = parsed.modifiers
        postEvent(keyUp, to: targetPID)
    }

    // MARK: - Private

    /// Post an event either to a specific process or globally
    private func postEvent(_ event: CGEvent, to pid: pid_t?) {
        if let pid = pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

public enum InputError: Error, Sendable {
    case eventCreationFailed
    case invalidKeySpec(String)
    case invalidModifier(String)
    case invalidKeyName(String)
}
