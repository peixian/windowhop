import XCTest
@testable import WindowHopCore

final class ShortcutConfigurationTests: XCTestCase {
    func testDefaultsPreserveExistingShortcuts() {
        let config = ShortcutConfiguration.defaults
        XCTAssertEqual(config.cycle, KeyboardShortcut(keyCode: 48, modifiers: .command))
        XCTAssertEqual(config.search, KeyboardShortcut(keyCode: 49, modifiers: .control))
        XCTAssertTrue(config.cycleEnabled)
        XCTAssertTrue(config.searchEnabled)
        XCTAssertTrue(config.fastSearchEnabled)
        XCTAssertEqual(config.fastSearchModifier, .rightOption)
        XCTAssertNil(config.validationError())
    }

    func testModifierBitsMatchCGEventsAndIgnoreIncidentalFlags() {
        XCTAssertEqual(ShortcutModifiers.shift.rawValue, 1 << 17)
        XCTAssertEqual(ShortcutModifiers.control.rawValue, 1 << 18)
        XCTAssertEqual(ShortcutModifiers.option.rawValue, 1 << 19)
        XCTAssertEqual(ShortcutModifiers.command.rawValue, 1 << 20)
        XCTAssertEqual(ShortcutModifiers.fn.rawValue, 1 << 23)
        let incidental: UInt64 = (1 << 16) | (1 << 21) | (1 << 22) | (1 << 63) | 0x40
        let flags = ShortcutModifiers(rawValue: incidental | (1 << 20) | (1 << 17))
        XCTAssertEqual(flags, [.command, .shift])
        XCTAssertEqual(ShortcutModifiers(rawValue: incidental), [])
        XCTAssertEqual(Set([flags, [.shift, .command]]).count, 1)
    }

    func testEnabledShortcutsRequireAModifierThatDoesNotCapturePlainTyping() {
        for modifiers: ShortcutModifiers in [[], [.shift]] {
            var config = ShortcutConfiguration.defaults
            config.search = KeyboardShortcut(keyCode: 0, modifiers: modifiers)
            XCTAssertNotNil(config.validationError())
        }
        for modifiers: ShortcutModifiers in [.command, .control, .option, .fn, [.command, .shift]] {
            var config = ShortcutConfiguration.defaults
            config.search = KeyboardShortcut(keyCode: 0, modifiers: modifiers)
            XCTAssertNil(config.validationError())
        }
    }

    func testEscapeModifierKeysAndOutOfRangeKeysAreRejected() {
        for key in [UInt16(53)] + Array(UInt16(54)...UInt16(63)) + [128, UInt16.max] {
            var config = ShortcutConfiguration.defaults
            config.search = KeyboardShortcut(keyCode: key, modifiers: .command)
            XCTAssertNotNil(config.validationError(), "key code \(key)")
        }
        // Modified Return, keypad Enter and function keys remain usable chords.
        for key: UInt16 in [36, 76, 96, 122, 127] {
            var config = ShortcutConfiguration.defaults
            config.search = KeyboardShortcut(keyCode: key, modifiers: .command)
            XCTAssertNil(config.validationError(), "key code \(key)")
        }
    }

    func testCycleReservesShiftAndItsReverseChordCannotOpenSearch() {
        var config = ShortcutConfiguration.defaults
        config.cycle.modifiers.insert(.shift)
        XCTAssertNotNil(config.validationError())
        config = .defaults
        config.search = config.cycle
        XCTAssertNotNil(config.validationError())
        config.search.modifiers.insert(.shift)
        XCTAssertNotNil(config.validationError())
        config.search.modifiers.insert(.control)
        XCTAssertNil(config.validationError())
    }

    func testDisabledBindingsDoNotReserveOrValidateTheirSavedChords() {
        var config = ShortcutConfiguration.defaults
        config.search = config.cycle
        config.cycleEnabled = false
        XCTAssertNil(config.validationError())
        config.cycle = KeyboardShortcut(keyCode: UInt16.max, modifiers: [])
        XCTAssertNil(config.validationError())
        config.searchEnabled = false
        config.search = KeyboardShortcut(keyCode: 53, modifiers: [])
        XCTAssertNil(config.validationError())
        config.cycleEnabled = true
        XCTAssertNotNil(config.validationError())
    }

    func testFastSearchAllowsExplicitChordsWithItsModifier() {
        for modifier in FastSearchModifier.allCases {
            var config = ShortcutConfiguration.defaults
            config.fastSearchModifier = modifier
            config.cycle = KeyboardShortcut(keyCode: 48, modifiers: .option)
            config.search = KeyboardShortcut(keyCode: 1, modifiers: .fn)
            XCTAssertNil(config.validationError(), modifier.rawValue)
        }
        XCTAssertEqual(FastSearchModifier.allCases.count, 7)
    }

    func testConfigurationRoundTripsEveryFastSearchModifierAndDisabledState() throws {
        for modifier in FastSearchModifier.allCases {
            let config = ShortcutConfiguration(
                cycle: KeyboardShortcut(keyCode: 96, modifiers: [.command, .control]),
                search: KeyboardShortcut(keyCode: 0, modifiers: [.option, .shift]),
                cycleEnabled: false, searchEnabled: true, fastSearchEnabled: false,
                fastSearchModifier: modifier)
            let encoded = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(ShortcutConfiguration.self, from: encoded), config)
        }
    }

    func testDecodingNormalizesRawModifierFlags() throws {
        let raw: UInt64 = (1 << 20) | (1 << 16) | (1 << 21) | 0x08
        let data = Data("{\"keyCode\":48,\"modifiers\":\(raw)}".utf8)
        let shortcut = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(shortcut, KeyboardShortcut(keyCode: 48, modifiers: .command))
        let encoded = try JSONEncoder().encode(shortcut.modifiers)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "1048576")
    }

    func testFunctionFlagClassificationIncludesHelpNavigationAndAllTwentyFunctionKeys() {
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                      103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let navigationKeys: [UInt16] = [114, 115, 119, 116, 121, 117, 123, 124, 125, 126]
        for key in functionKeys + navigationKeys {
            XCTAssertTrue(KeyboardShortcut.hasImplicitFunctionFlag(keyCode: key), "key code \(key)")
        }
        // Backspace, Tab, Return, keypad Enter and modifier keys carry no such flag.
        for key: UInt16 in [0, 36, 48, 49, 51, 53, 54, 57, 63, 65, 76, 127] {
            XCTAssertFalse(KeyboardShortcut.hasImplicitFunctionFlag(keyCode: key), "key code \(key)")
        }
    }

    func testExplicitFnWithNavigationOrFunctionKeysIsRejectedButControlChordsWork() {
        for key: UInt16 in [114, 115, 119, 116, 121, 117, 123, 124, 125, 126, 122, 64, 90] {
            var config = ShortcutConfiguration.defaults
            config.search = KeyboardShortcut(keyCode: key, modifiers: [.control, .fn])
            XCTAssertNotNil(config.validationError(), "search key code \(key)")
            config.search.modifiers.remove(.fn)
            XCTAssertNil(config.validationError(), "search key code \(key)")
            config = .defaults
            config.cycle = KeyboardShortcut(keyCode: key, modifiers: [.control, .fn])
            XCTAssertNotNil(config.validationError(), "cycle key code \(key)")
            config.cycle.modifiers.remove(.fn)
            XCTAssertNil(config.validationError(), "cycle key code \(key)")
        }
        var config = ShortcutConfiguration.defaults
        config.search = KeyboardShortcut(keyCode: 0, modifiers: .fn)
        XCTAssertNil(config.validationError())
    }
    func testOlderSettingsKeepCustomChordsAndGainAdditionalDefaults() throws {
        let data = Data("""
        {"cycle":{"keyCode":38,"modifiers":1048576},"search":{"keyCode":40,"modifiers":262144},"cycleEnabled":false,"searchEnabled":true,"fastSearchEnabled":false,"fastSearchModifier":"fn"}
        """.utf8)
        let restored = try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        XCTAssertEqual(restored.cycle.keyCode, 38)
        XCTAssertEqual(restored.search.keyCode, 40)
        XCTAssertFalse(restored.cycleEnabled)
        XCTAssertFalse(restored.fastSearchEnabled)
        XCTAssertEqual(restored.fastSearchModifier, .fn)
        XCTAssertEqual(restored.appCycle, KeyboardShortcut(keyCode: 50, modifiers: .command))
        XCTAssertTrue(restored.appCycleEnabled)
        XCTAssertEqual(restored.alternateCycle, KeyboardShortcut(keyCode: 48, modifiers: .option))
        XCTAssertFalse(restored.alternateCycleEnabled)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutConfiguration.self, from: JSONEncoder().encode(restored)), restored)
    }

    func testAdditionalSwitchersReserveReverseChordsAndCanBeDisabledIndependently() {
        var config = ShortcutConfiguration.defaults
        config.alternateCycleEnabled = true
        XCTAssertNil(config.validationError())
        config.appCycle = config.cycle
        XCTAssertNotNil(config.validationError())
        config.appCycleEnabled = false
        XCTAssertNil(config.validationError())
        config.search = KeyboardShortcut(keyCode: config.alternateCycle.keyCode, modifiers: config.alternateCycle.modifiers.union(.shift))
        XCTAssertNotNil(config.validationError())
        config.alternateCycleEnabled = false
        XCTAssertNil(config.validationError())
        config.appCycleEnabled = true
        config.appCycle = KeyboardShortcut(keyCode: 50, modifiers: [.command, .shift])
        XCTAssertNotNil(config.validationError())
    }

    func testMigratingCustomBackquoteBindingDoesNotIntroduceAConflict() throws {
        let data = Data("""
        {"cycle":{"keyCode":50,"modifiers":1048576},"search":{"keyCode":49,"modifiers":262144},"cycleEnabled":true,"searchEnabled":true,"fastSearchEnabled":true,"fastSearchModifier":"rightOption"}
        """.utf8)
        let restored = try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        XCTAssertTrue(restored.cycleEnabled)
        XCTAssertFalse(restored.appCycleEnabled)
        XCTAssertNil(restored.validationError())
    }

}
