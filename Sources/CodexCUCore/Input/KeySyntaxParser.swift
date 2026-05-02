import CoreGraphics
import Carbon.HIToolbox

/// Parses xdotool-style key syntax into CGKeyCode + CGEventFlags
public struct KeySyntaxParser: Sendable {
    public init() {}

    public struct ParsedKey: Sendable {
        public let keyCode: CGKeyCode
        public let modifiers: CGEventFlags
    }

    /// Parse a key specification like "super+c", "ctrl+shift+a", "Return", "Tab"
    public func parse(_ spec: String) throws -> ParsedKey {
        let parts = spec.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else {
            throw InputError.invalidKeySpec(spec)
        }

        var modifiers: CGEventFlags = []
        let keyName = parts.last!

        // Parse modifier prefixes
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "super", "command", "cmd", "meta":
                modifiers.insert(.maskCommand)
            case "ctrl", "control":
                modifiers.insert(.maskControl)
            case "alt", "option", "opt":
                modifiers.insert(.maskAlternate)
            case "shift":
                modifiers.insert(.maskShift)
            case "fn", "function":
                modifiers.insert(.maskSecondaryFn)
            default:
                throw InputError.invalidModifier(modifier)
            }
        }

        // If only one part and it's a modifier key itself, it's the key
        guard let keyCode = keyCodeForName(keyName) ?? keyCodeForCharacter(keyName) else {
            throw InputError.invalidKeyName(keyName)
        }

        return ParsedKey(keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCodeForName(_ name: String) -> CGKeyCode? {
        let lowered = name.lowercased()
        return Self.namedKeys[lowered]
    }

    private func keyCodeForCharacter(_ char: String) -> CGKeyCode? {
        guard char.count == 1 else { return nil }
        let c = char.lowercased()
        return Self.charKeys[c]
    }

    // MARK: - Key maps

    private static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return),
        "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab),
        "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete),
        "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape),
        "esc": CGKeyCode(kVK_Escape),
        "up": CGKeyCode(kVK_UpArrow),
        "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow),
        "right": CGKeyCode(kVK_RightArrow),
        "home": CGKeyCode(kVK_Home),
        "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp),
        "page_up": CGKeyCode(kVK_PageUp),
        "pagedown": CGKeyCode(kVK_PageDown),
        "page_down": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1),
        "f2": CGKeyCode(kVK_F2),
        "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4),
        "f5": CGKeyCode(kVK_F5),
        "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7),
        "f8": CGKeyCode(kVK_F8),
        "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10),
        "f11": CGKeyCode(kVK_F11),
        "f12": CGKeyCode(kVK_F12),
        "kp_0": CGKeyCode(kVK_ANSI_Keypad0),
        "kp_1": CGKeyCode(kVK_ANSI_Keypad1),
        "kp_2": CGKeyCode(kVK_ANSI_Keypad2),
        "kp_3": CGKeyCode(kVK_ANSI_Keypad3),
        "kp_4": CGKeyCode(kVK_ANSI_Keypad4),
        "kp_5": CGKeyCode(kVK_ANSI_Keypad5),
        "kp_6": CGKeyCode(kVK_ANSI_Keypad6),
        "kp_7": CGKeyCode(kVK_ANSI_Keypad7),
        "kp_8": CGKeyCode(kVK_ANSI_Keypad8),
        "kp_9": CGKeyCode(kVK_ANSI_Keypad9),
    ]

    private static let charKeys: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B),
        "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J),
        "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N),
        "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V),
        "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
        "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal),
        "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
        "\\": CGKeyCode(kVK_ANSI_Backslash), ";": CGKeyCode(kVK_ANSI_Semicolon),
        "'": CGKeyCode(kVK_ANSI_Quote), ",": CGKeyCode(kVK_ANSI_Comma),
        ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash),
        "`": CGKeyCode(kVK_ANSI_Grave),
    ]
}
