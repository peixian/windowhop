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
    public var appCycle: KeyboardShortcut
    public var alternateCycle: KeyboardShortcut
    public var cycleEnabled: Bool
    public var searchEnabled: Bool
    public var appCycleEnabled: Bool
    public var alternateCycleEnabled: Bool
    public var fastSearchEnabled: Bool
    public var fastSearchModifier: FastSearchModifier

    public static let defaults = ShortcutConfiguration()

    public init(
        cycle: KeyboardShortcut = KeyboardShortcut(keyCode: 48, modifiers: .command),
        search: KeyboardShortcut = KeyboardShortcut(keyCode: 49, modifiers: .control),
        cycleEnabled: Bool = true,
        searchEnabled: Bool = true,
        fastSearchEnabled: Bool = true,
        fastSearchModifier: FastSearchModifier = .rightOption,
        appCycle: KeyboardShortcut = KeyboardShortcut(keyCode: 50, modifiers: .command),
        alternateCycle: KeyboardShortcut = KeyboardShortcut(keyCode: 48, modifiers: .option),
        appCycleEnabled: Bool = true,
        alternateCycleEnabled: Bool = false
    ) {
        self.cycle = cycle
        self.search = search
        self.cycleEnabled = cycleEnabled
        self.searchEnabled = searchEnabled
        self.fastSearchEnabled = fastSearchEnabled
        self.fastSearchModifier = fastSearchModifier
        self.appCycle = appCycle
        self.alternateCycle = alternateCycle
        self.appCycleEnabled = appCycleEnabled
        self.alternateCycleEnabled = alternateCycleEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case cycle, search, appCycle, alternateCycle
        case cycleEnabled, searchEnabled, appCycleEnabled, alternateCycleEnabled
        case fastSearchEnabled, fastSearchModifier
    }

    /// Settings saved before additional switchers existed retain their original
    /// bindings. Missing new fields inherit defaults instead of losing all settings.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        cycle = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .cycle) ?? fallback.cycle
        search = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .search) ?? fallback.search
        appCycle = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .appCycle) ?? fallback.appCycle
        alternateCycle = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .alternateCycle) ?? fallback.alternateCycle
        cycleEnabled = try values.decodeIfPresent(Bool.self, forKey: .cycleEnabled) ?? fallback.cycleEnabled
        searchEnabled = try values.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? fallback.searchEnabled
        appCycleEnabled = try values.decodeIfPresent(Bool.self, forKey: .appCycleEnabled) ?? fallback.appCycleEnabled
        alternateCycleEnabled = try values.decodeIfPresent(Bool.self, forKey: .alternateCycleEnabled) ?? fallback.alternateCycleEnabled
        fastSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .fastSearchEnabled) ?? fallback.fastSearchEnabled
        fastSearchModifier = try values.decodeIfPresent(FastSearchModifier.self, forKey: .fastSearchModifier) ?? fallback.fastSearchModifier
        // Do not invalidate a preexisting custom shortcut by enabling a new
        // default binding that claims the same chord during migration.
        if !values.contains(.appCycleEnabled) {
            let candidates = [appCycle, KeyboardShortcut(keyCode: appCycle.keyCode, modifiers: appCycle.modifiers.union(.shift))]
            let existing = (cycleEnabled ? [cycle, KeyboardShortcut(keyCode: cycle.keyCode, modifiers: cycle.modifiers.union(.shift))] : []) + (searchEnabled ? [search] : [])
            if candidates.contains(where: existing.contains) { appCycleEnabled = false }
        }
    }

    /// Disabled bindings do not reserve a chord. Every cycle binding reserves
    /// its Shift variant for reverse cycling. Fast Search yields to explicit chords.
    public func validationError() -> String? {
        let bindings: [(String, KeyboardShortcut, Bool, Bool)] = [
            ("Window cycling", cycle, cycleEnabled, true),
            ("Frontmost-app cycling", appCycle, appCycleEnabled, true),
            ("Alternate cycling", alternateCycle, alternateCycleEnabled, true),
            ("Window search", search, searchEnabled, false)
        ]
        var reserved: [(String, KeyboardShortcut)] = []
        for (name, shortcut, enabled, isCycle) in bindings where enabled {
            if let error = Self.validate(shortcut, name: name) { return error }
            if isCycle && shortcut.modifiers.contains(.shift) {
                return "\(name) reserves Shift for switching in reverse. Choose a shortcut without Shift."
            }
            var chords = [shortcut]
            if isCycle {
                chords.append(KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.union(.shift)))
            }
            for chord in chords {
                if let conflict = reserved.first(where: { $0.1 == chord }) {
                    return "\(name) conflicts with \(conflict.0.lowercased()). Choose different shortcuts, including their Shift variants."
                }
            }
            reserved.append(contentsOf: chords.map { (name, $0) })
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
