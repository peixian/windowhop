import Foundation

/// The semantic modifier bits shared by CGEventFlags and NSEvent.ModifierFlags.
/// Caps Lock, device-side bits, keypad and Help flags do not change a chord.
public struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable {
    public let rawValue: UInt64

    private static let knownMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)

    public init(rawValue: UInt64) {
        self.rawValue = rawValue & Self.knownMask
    }

    public static let shift = ShortcutModifiers(rawValue: 1 << 17)
    public static let control = ShortcutModifiers(rawValue: 1 << 18)
    public static let option = ShortcutModifiers(rawValue: 1 << 19)
    public static let command = ShortcutModifiers(rawValue: 1 << 20)
    public static let fn = ShortcutModifiers(rawValue: 1 << 23)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A physical macOS key code, independent of the currently selected input layout.
public struct KeyboardShortcut: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// AppKit's function flag describes these keys even without a physical Fn
    /// press. Recorders and event matching must remove that implicit flag.
    /// https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/function
    public static func hasImplicitFunctionFlag(keyCode: UInt16) -> Bool {
        switch keyCode {
        // F1 through F20, in physical function-key order.
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
             103, 111, 105, 107, 113, 106, 64, 79, 80, 90:
            return true
        // Help, Home, End, Page Up/Down, Forward Delete, and the four arrows.
        case 114, 115, 119, 116, 121, 117, 123, 124, 125, 126:
            return true
        default:
            return false
        }
    }
}

public enum FastSearchModifier: String, Codable, CaseIterable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case leftControl
    case fn
}

public struct ShortcutConfiguration: Codable, Equatable {
    public var cycle: KeyboardShortcut
    public var search: KeyboardShortcut
    public var cycleEnabled: Bool
    public var searchEnabled: Bool
    public var fastSearchEnabled: Bool
    public var fastSearchModifier: FastSearchModifier

    public static let defaults = ShortcutConfiguration()

    public init(
        cycle: KeyboardShortcut = KeyboardShortcut(keyCode: 48, modifiers: .command),
        search: KeyboardShortcut = KeyboardShortcut(keyCode: 49, modifiers: .control),
        cycleEnabled: Bool = true,
        searchEnabled: Bool = true,
        fastSearchEnabled: Bool = true,
        fastSearchModifier: FastSearchModifier = .rightOption
    ) {
        self.cycle = cycle
        self.search = search
        self.cycleEnabled = cycleEnabled
        self.searchEnabled = searchEnabled
        self.fastSearchEnabled = fastSearchEnabled
        self.fastSearchModifier = fastSearchModifier
    }

    /// Disabled bindings may keep their saved chords without blocking another
    /// binding. Cycle's Shift variant belongs to reverse cycling. Fast Search
    /// yields to explicit chords, so its modifier may also occur in either chord.
    public func validationError() -> String? {
        if cycleEnabled {
            if let error = Self.validate(cycle, name: "Window cycling") { return error }
            if cycle.modifiers.contains(.shift) {
                return "Window cycling reserves Shift for switching in reverse. Choose a shortcut without Shift."
            }
        }
        if searchEnabled {
            if let error = Self.validate(search, name: "Window search") { return error }
        }
        if cycleEnabled && searchEnabled && cycle.keyCode == search.keyCode {
            if cycle.modifiers == search.modifiers {
                return "Window cycling and window search need different shortcuts."
            }
            if cycle.modifiers.union(.shift) == search.modifiers {
                return "That search shortcut is already used for reverse window cycling."
            }
        }
        return nil
    }

    private static func validate(_ shortcut: KeyboardShortcut, name: String) -> String? {
        guard shortcut.keyCode <= 127 else {
            return "\(name) needs a physical keyboard key with a supported key code."
        }
        guard !(54...63).contains(shortcut.keyCode) else {
            return "\(name) needs a non-modifier key in addition to its modifiers."
        }
        guard shortcut.keyCode != 53 else {
            return "Escape is reserved for cancelling the switcher. Choose another key for \(name.lowercased())."
        }
        if shortcut.modifiers.contains(.fn), KeyboardShortcut.hasImplicitFunctionFlag(keyCode: shortcut.keyCode) {
            return "Fn cannot be distinguished from the key itself for navigation and function keys. Use Command, Control, or Option instead."
        }
        let required: ShortcutModifiers = [.command, .control, .option, .fn]
        guard !shortcut.modifiers.intersection(required).isEmpty else {
            return "\(name) needs Command, Control, Option, or Fn to avoid capturing ordinary typing."
        }
        return nil
    }
}
