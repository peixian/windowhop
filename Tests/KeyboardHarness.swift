// Concatenated after KeyboardController.swift by scripts/test-keyboard.sh.
// Synthetic events are filtered in memory; no event tap is installed or event posted.

extension KeyboardController {
    func synthetic(_ type: CGEventType, _ key: Int, _ flags: CGEventFlags = [], repeatKey: Bool = false, text: String? = nil) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: type != .keyUp)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        if let text {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
        }
        return filter(type: type, event: event) == nil
    }
    func loadSyntheticLayout() { cacheKeyboardLayout() }
    func syntheticSearchReady(_ deliver: (NSEvent) -> Void) {
        completeSearchPreparation(windowNumber: 12345, deliver: deliver)
    }
}

let app = NSApplication.shared
let keyboard = KeyboardController()
var actions = [String]()
keyboard.onAction = { actions.append(String(describing: $0)) }
func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
check(keyboard.synthetic(.keyDown, kVK_Tab, .maskCommand), "Command Tab capture")
check(keyboard.mode == .cycle, "cycle started")
check(keyboard.synthetic(.keyUp, kVK_Tab, .maskCommand), "paired Tab up captured")
check(keyboard.synthetic(.keyDown, kVK_Tab, [.maskCommand, .maskShift]), "reverse capture")
check(!keyboard.synthetic(.flagsChanged, kVK_Command), "modifier event preserved")
check(keyboard.mode == .hidden, "release ends cycle")
check(keyboard.synthetic(.keyDown, kVK_Tab, [], repeatKey: true), "no held Tab repeat leak after commit")
check(keyboard.synthetic(.keyUp, kVK_Tab), "paired Tab up after commit")
flush()
check(actions == ["beginCycle(reverse: false)", "cycle(reverse: true)", "commit"], "ordered cycle actions")
actions.removeAll()
keyboard.commandTabEnabled = false
check(!keyboard.synthetic(.keyDown, kVK_Tab, .maskCommand), "native Command Tab fallback")
keyboard.commandTabEnabled = true
check(keyboard.synthetic(.keyDown, kVK_Space, .maskControl), "search shortcut captured")
check(keyboard.mode == .search, "search started")
keyboard.syntheticSearchReady { _ in preconditionFailure("No early input expected") }
check(!keyboard.synthetic(.keyDown, kVK_ANSI_A), "native search text preserved")
check(keyboard.synthetic(.keyDown, kVK_DownArrow), "search navigation captured")
check(keyboard.synthetic(.keyDown, kVK_Escape), "search cancellation captured")
flush()
check(actions == ["showSearch", "move(1)", "cancel"], "search actions")
actions.removeAll()
keyboard.loadSyntheticLayout()
let rightOption = CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 0x40))
check(!keyboard.synthetic(.keyDown, kVK_ANSI_A, .maskAlternate), "left Option preserved")
check(keyboard.synthetic(.keyDown, kVK_ANSI_A, rightOption), "right Option text captured")
check(keyboard.mode == .fastSearch, "fast search started")
check(!keyboard.synthetic(.flagsChanged, kVK_RightOption), "Option release preserved")
check(keyboard.mode == .hidden, "Option release commits")
check(keyboard.synthetic(.keyDown, kVK_ANSI_A, [], repeatKey: true), "held text repeat does not leak after release")
check(keyboard.synthetic(.keyUp, kVK_ANSI_A), "paired fast key up captured")
flush()
check(actions.count == 2 && actions[0].hasPrefix("beginFastSearch(") && actions[1] == "commit", "fast search actions")
actions.removeAll()
check(keyboard.synthetic(.keyDown, kVK_ANSI_B, rightOption), "fast search restarts")
check(keyboard.synthetic(.keyDown, kVK_Escape, rightOption), "fast Escape")
check(!keyboard.synthetic(.keyDown, kVK_ANSI_C, rightOption), "Escape blocks reopening while modifier held")
check(keyboard.mode == .hidden, "still hidden until modifier released")
_ = keyboard.synthetic(.flagsChanged, kVK_RightOption)
check(keyboard.synthetic(.keyDown, kVK_ANSI_D, rightOption), "next modifier gesture can search")
flush()
check(actions.count == 3 && actions[1] == "cancel", "fast cancellation actions")
keyboard.mode = .hidden
keyboard.fastSearchModifier = .fn
_ = keyboard.synthetic(.flagsChanged, kVK_Function)
check(keyboard.synthetic(.keyDown, kVK_ANSI_E, .maskSecondaryFn), "Fn text captured")
check(keyboard.mode == .fastSearch, "Fn mode starts")
_ = keyboard.synthetic(.flagsChanged, kVK_Function)
check(keyboard.mode == .hidden, "Fn release commits")
flush()

for iteration in 0..<100 {
    let opening = KeyboardController()
    check(opening.synthetic(.keyDown, kVK_Space, .maskControl), "opening shortcut \(iteration)")
    check(opening.synthetic(.keyDown, kVK_ANSI_A, [], text: "あ"), "early Unicode input captured")
    check(opening.synthetic(.keyUp, kVK_ANSI_A), "early paired keyup captured")
    check(opening.synthetic(.keyDown, kVK_Return), "early Return captured")
    check(opening.synthetic(.keyDown, kVK_ANSI_B, [], text: "b"), "trailing input captured")
    var replay: [NSEvent] = []
    opening.syntheticSearchReady { event in
        replay.append(event)
        if event.keyCode == UInt16(kVK_Return) { opening.mode = .hidden }
    }
    check(replay.map(\.keyCode) == [UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_A), UInt16(kVK_Return)], "replay order and stop after commit")
    check(replay[0].characters == "あ", "native Unicode retained")
    check(replay[0].windowNumber == 12345, "replay targets only WindowHop's window")
    check(replay[0].type == .keyDown && replay[1].type == .keyUp, "native down/up retained")
    check(opening.synthetic(.keyUp, kVK_ANSI_B), "discarded trailing keyup suppressed")
}

let interrupted = KeyboardController()
_ = interrupted.synthetic(.keyDown, kVK_Space, .maskControl)
check(interrupted.synthetic(.keyDown, kVK_ANSI_A), "early input buffered before new gesture")
check(interrupted.synthetic(.keyDown, kVK_Tab, .maskCommand), "new cycle interrupts search preparation")
interrupted.syntheticSearchReady { _ in preconditionFailure("Interrupted search must not replay into new session") }
check(interrupted.synthetic(.keyUp, kVK_ANSI_A, .maskCommand), "discarded input keyup remains suppressed")

let overflowing = KeyboardController()
_ = overflowing.synthetic(.keyDown, kVK_Space, .maskControl)
for _ in 0..<513 {
    check(overflowing.synthetic(.keyDown, kVK_ANSI_A), "buffer overflow input remains captured")
}
overflowing.syntheticSearchReady { _ in preconditionFailure("Overflow must discard all input") }
check(overflowing.mode == .hidden, "overflow cancels safely")
check(overflowing.synthetic(.keyUp, kVK_ANSI_A), "overflow retains keyup suppression")
flush()

let custom = KeyboardController()
var customActions: [String] = []
custom.onAction = { customActions.append(String(describing: $0)) }
custom.configuration = ShortcutConfiguration(
    cycle: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option]),
    search: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])
)
check(!custom.synthetic(.keyDown, kVK_Tab, .maskCommand), "default cycle chord is no longer captured")
check(!custom.synthetic(.keyDown, kVK_ANSI_J, [.maskControl, .maskAlternate, .maskCommand]), "extra modifier must not match cycle")
check(custom.synthetic(.keyDown, kVK_ANSI_J, [.maskControl, .maskAlternate, .maskAlphaShift, .maskNumericPad]), "custom cycle ignores Caps/keypad flags")
check(custom.synthetic(.keyUp, kVK_ANSI_J, [.maskControl, .maskAlternate]), "custom cycle owns paired keyup")
check(custom.synthetic(.keyDown, kVK_ANSI_J, [.maskControl, .maskAlternate, .maskShift]), "custom cycle reverse")
_ = custom.synthetic(.flagsChanged, kVK_Shift, [.maskControl, .maskAlternate])
check(custom.mode == .cycle, "reverse modifier release does not commit")
_ = custom.synthetic(.flagsChanged, kVK_Control, .maskAlternate)
check(custom.mode == .hidden, "releasing any required base modifier commits")
check(custom.synthetic(.keyUp, kVK_ANSI_J, .maskAlternate), "custom captured keyup remains owned after commit")
flush()
check(customActions == ["beginCycle(reverse: false)", "cycle(reverse: true)", "commit"], "custom cycle action order")
customActions.removeAll()
check(!custom.synthetic(.keyDown, kVK_ANSI_K, .maskCommand), "search requires configured Shift")
check(custom.synthetic(.keyDown, kVK_ANSI_K, [.maskCommand, .maskShift]), "custom search opens")
custom.syntheticSearchReady { _ in preconditionFailure("No buffered custom-search text expected") }
check(!custom.synthetic(.keyDown, kVK_ANSI_A), "custom search retains native editing")
check(custom.synthetic(.keyDown, kVK_Escape), "custom search cancels")
flush()
check(customActions == ["showSearch", "cancel"], "custom search action order")

let live = KeyboardController()
var liveActions: [String] = []
live.onAction = { liveActions.append(String(describing: $0)) }
check(live.synthetic(.keyDown, kVK_Tab, .maskCommand), "old cycle begins before config change")
live.configuration.cycleEnabled = false
check(live.mode == .hidden, "configuration change immediately cancels active cycle")
check(live.synthetic(.keyUp, kVK_Tab), "config change retains old keyup ownership")
check(!live.synthetic(.keyDown, kVK_Tab, .maskCommand), "disabled cycle preserves native chord")
flush()
check(liveActions == ["cancel"], "config change discards pending old begin action")

let disabled = KeyboardController()
disabled.loadSyntheticLayout()
disabled.configuration = ShortcutConfiguration(cycleEnabled: false, searchEnabled: false, fastSearchEnabled: false)
_ = disabled.synthetic(.flagsChanged, kVK_RightOption)
check(!disabled.synthetic(.keyDown, kVK_Tab, .maskCommand), "disabled cycle passes")
check(!disabled.synthetic(.keyDown, kVK_Space, .maskControl), "disabled search passes")
check(!disabled.synthetic(.keyDown, kVK_ANSI_A, rightOption), "disabled Fast Search passes")
check(disabled.mode == .hidden, "all disabled leaves modes hidden")

let modifierCases: [(FastSearchModifier, CGEventFlags, UInt64, UInt64)] = [
    (.leftOption, .maskAlternate, 0x20, 0x40), (.rightOption, .maskAlternate, 0x40, 0x20),
    (.leftCommand, .maskCommand, 0x8, 0x10), (.rightCommand, .maskCommand, 0x10, 0x8),
    (.leftControl, .maskControl, 0x1, 0x2000), (.rightControl, .maskControl, 0x2000, 0x1),
    (.fn, .maskSecondaryFn, CGEventFlags.maskSecondaryFn.rawValue, 0)
]
for (modifier, aggregate, side, opposite) in modifierCases {
    let fast = KeyboardController()
    fast.configuration.fastSearchModifier = modifier
    fast.loadSyntheticLayout()
    _ = fast.synthetic(.flagsChanged, kVK_Function)
    let flags = aggregate.union(CGEventFlags(rawValue: side))
    if opposite != 0 {
        let otherSide = aggregate.union(CGEventFlags(rawValue: opposite))
        check(!fast.synthetic(.keyDown, kVK_ANSI_A, otherSide), "wrong Fast Search side passes for \(modifier)")
        check(!fast.synthetic(.keyDown, kVK_ANSI_A, flags.union(CGEventFlags(rawValue: opposite))), "both sides rejected for \(modifier)")
    }
    let extra: CGEventFlags = aggregate == .maskCommand ? .maskControl : .maskCommand
    check(!fast.synthetic(.keyDown, kVK_ANSI_A, flags.union(extra)), "additional modifier rejected for \(modifier)")
    check(fast.synthetic(.keyDown, kVK_ANSI_A, flags.union([.maskShift, .maskAlphaShift])), "selected modifier accepts text and Shift/Caps for \(modifier)")
    check(fast.mode == .fastSearch, "configured Fast Search starts for \(modifier)")
    _ = fast.synthetic(.flagsChanged, kVK_Function)
    check(fast.mode == .hidden, "configured modifier release commits for \(modifier)")
    check(fast.synthetic(.keyUp, kVK_ANSI_A), "Fast Search owns paired keyup for \(modifier)")
}

for key in [kVK_UpArrow, kVK_F5, kVK_Home, kVK_Help] {
    let functionChord = KeyboardController()
    functionChord.configuration = ShortcutConfiguration(
        cycle: KeyboardShortcut(keyCode: UInt16(key), modifiers: .control),
        searchEnabled: false, fastSearchEnabled: false
    )
    check(functionChord.synthetic(.keyDown, key, [.maskControl, .maskSecondaryFn]), "synthetic Fn ignored for custom chord \(key)")
    _ = functionChord.synthetic(.flagsChanged, kVK_Shift, .maskControl)
    check(functionChord.mode == .cycle, "synthetic Fn is not a required held modifier")
    _ = functionChord.synthetic(.flagsChanged, kVK_Control)
    check(functionChord.mode == .hidden, "function/navigation cycle releases correctly")
}

let nativeNavigation = KeyboardController()
nativeNavigation.loadSyntheticLayout()
check(nativeNavigation.synthetic(.keyDown, kVK_ANSI_A, rightOption), "Fast Search before navigation")
check(nativeNavigation.synthetic(.keyDown, kVK_DownArrow, rightOption.union(.maskSecondaryFn)), "implicit Fn navigation remains captured")
check(nativeNavigation.mode == .fastSearch, "implicit Fn does not cancel Fast Search")
_ = nativeNavigation.synthetic(.flagsChanged, kVK_Command, rightOption.union(.maskCommand))
check(nativeNavigation.mode == .fastSearch, "adding Command keeps Fast Search open for direct selection")
check(!nativeNavigation.synthetic(.keyDown, kVK_ANSI_B, rightOption.union(.maskCommand)), "unrelated Command shortcut passes through Fast Search")
check(nativeNavigation.mode == .hidden, "unrelated Command shortcut cancels Fast Search")
flush()

let resumed = KeyboardController()
resumed.configuration = ShortcutConfiguration(
    cycle: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: .command),
    search: KeyboardShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: .control)
)
resumed.loadSyntheticLayout()
resumed.stop()
var resumeActions: [String] = []
resumed.onAction = { resumeActions.append(String(describing: $0)) }
check(resumed.synthetic(.keyDown, kVK_ANSI_J, .maskCommand, repeatKey: true), "resumed cycle repeat is consumed")
check(resumed.mode == .hidden, "resumed cycle repeat cannot start switching")
check(resumed.synthetic(.keyUp, kVK_ANSI_J, .maskCommand), "resumed cycle repeat owns keyup")
check(resumed.synthetic(.keyDown, kVK_ANSI_K, .maskControl, repeatKey: true), "resumed search repeat is consumed")
check(resumed.mode == .hidden, "resumed search repeat cannot open search")
check(resumed.synthetic(.keyUp, kVK_ANSI_K, .maskControl), "resumed search repeat owns keyup")
check(resumed.synthetic(.keyDown, kVK_ANSI_A, rightOption, repeatKey: true), "resumed Fast Search repeat is consumed")
check(resumed.mode == .hidden, "resumed Fast Search repeat cannot start search")
check(resumed.synthetic(.keyUp, kVK_ANSI_A, rightOption), "resumed Fast Search repeat owns keyup")
flush()
check(resumeActions.isEmpty, "holding keys across resume emits no actions")
check(resumed.synthetic(.keyDown, kVK_ANSI_J, .maskCommand), "fresh press after resume starts cycle")
check(resumed.synthetic(.keyDown, kVK_ANSI_J, .maskCommand, repeatKey: true), "active cycle autorepeat remains captured")
flush()
check(resumeActions == ["beginCycle(reverse: false)", "cycle(reverse: false)"], "active cycling still repeats")

let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
for (index, key) in numberKeys.enumerated() {
    let direct = KeyboardController()
    direct.mode = .search
    direct.resultCount = 9
    var selections: [String] = []
    direct.onAction = { selections.append(String(describing: $0)) }
    let commandFlags = CGEventFlags.maskCommand.union(.maskAlphaShift).union(CGEventFlags(rawValue: 0x8))
    check(direct.synthetic(.keyDown, key, commandFlags), "Cmd-number is consumed for row \(index)")
    check(direct.mode == .hidden && direct.resultCount == 0, "valid direct selection ends session and clears count")
    check(direct.synthetic(.keyDown, key, .maskCommand, repeatKey: true), "held direct-selection number does not leak")
    check(direct.synthetic(.keyUp, key, .maskCommand), "direct selection retains keyup ownership")
    flush()
    check(selections == ["selectAndCommit(\(index))"], "number maps to correct zero-based row")
    check(!direct.synthetic(.keyDown, key, .maskCommand), "hidden Cmd-number remains native")
}

let invalidDirect = KeyboardController()
invalidDirect.mode = .search
invalidDirect.resultCount = 2
var invalidSelections: [String] = []
invalidDirect.onAction = { invalidSelections.append(String(describing: $0)) }
check(invalidDirect.synthetic(.keyDown, kVK_ANSI_9, .maskCommand), "nonexistent direct result is consumed")
check(invalidDirect.mode == .search && invalidDirect.resultCount == 2, "nonexistent result keeps panel open")
check(invalidDirect.synthetic(.keyDown, kVK_ANSI_9, .maskCommand, repeatKey: true), "nonexistent result repeat stays consumed")
check(invalidDirect.synthetic(.keyUp, kVK_ANSI_9), "invalid direct-selection keyup is owned")
check(!invalidDirect.synthetic(.keyDown, kVK_ANSI_1, [.maskCommand, .maskShift]), "shifted number is not direct selection")
check(!invalidDirect.synthetic(.keyDown, kVK_ANSI_1, [.maskCommand, .maskAlternate]), "extra Option is not direct selection")
check(!invalidDirect.synthetic(.keyDown, kVK_ANSI_0, .maskCommand), "Cmd-zero is not direct selection")
flush()
check(invalidSelections.isEmpty, "invalid or modified number emits no selection")

let directPriority = KeyboardController()
directPriority.configuration.cycle = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_2), modifiers: .command)
directPriority.mode = .search
directPriority.resultCount = 3
var priorityActions: [String] = []
directPriority.onAction = { priorityActions.append(String(describing: $0)) }
check(directPriority.synthetic(.keyDown, kVK_ANSI_2, .maskCommand), "direct selection precedes configured chord while open")
_ = directPriority.synthetic(.keyUp, kVK_ANSI_2)
flush()
check(priorityActions == ["selectAndCommit(1)"], "open-panel command selects instead of reopening")
check(directPriority.synthetic(.keyDown, kVK_ANSI_2, .maskCommand), "hidden configured number chord still opens cycle")
directPriority.resultCount = 3
check(directPriority.synthetic(.keyDown, kVK_ANSI_3, .maskCommand), "cycle supports direct selection")
flush()
check(priorityActions.suffix(2) == ["beginCycle(reverse: false)", "selectAndCommit(2)"], "cycle direct-selection action order")

let bufferedDirect = KeyboardController()
_ = bufferedDirect.synthetic(.keyDown, kVK_Space, .maskControl)
bufferedDirect.resultCount = 4
check(bufferedDirect.synthetic(.keyDown, kVK_ANSI_2, .maskCommand), "opening search buffers Cmd-number")
check(bufferedDirect.mode == .search, "opening search never prematurely commits")
var bufferedNumberKeys: [UInt16] = []
bufferedDirect.syntheticSearchReady { event in
    bufferedNumberKeys.append(event.keyCode)
    bufferedDirect.mode = .hidden
}
check(bufferedNumberKeys == [UInt16(kVK_ANSI_2)], "early number reaches own native panel")
check(bufferedDirect.synthetic(.keyUp, kVK_ANSI_2), "buffered number keyup stays captured after native commit")

let fastDirect = KeyboardController()
fastDirect.configuration.fastSearchModifier = .rightCommand
fastDirect.loadSyntheticLayout()
_ = fastDirect.synthetic(.flagsChanged, kVK_Command)
let rightCommand = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 0x10))
check(fastDirect.synthetic(.keyDown, kVK_ANSI_A, rightCommand), "Command Fast Search starts")
fastDirect.resultCount = 4
check(fastDirect.synthetic(.keyDown, kVK_ANSI_B, rightCommand), "Fast Search query changes")
check(fastDirect.resultCount == 0, "pending Fast Search query invalidates old result count")
check(fastDirect.synthetic(.keyDown, kVK_ANSI_3, rightCommand), "stale count number is consumed")
check(fastDirect.mode == .fastSearch, "stale count cannot commit wrong query")
_ = fastDirect.synthetic(.keyUp, kVK_ANSI_3, rightCommand)
fastDirect.resultCount = 4
check(fastDirect.synthetic(.keyDown, kVK_ANSI_3, rightCommand), "published Fast Search results support direct selection")
check(fastDirect.mode == .hidden, "valid Fast Search direct selection commits")

let heldCycle = KeyboardController()
heldCycle.configuration.cycle = KeyboardShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: [.control, .option])
check(heldCycle.synthetic(.keyDown, kVK_ANSI_J, [.maskControl, .maskAlternate]), "custom held-modifier cycle opens")
heldCycle.resultCount = 3
_ = heldCycle.synthetic(.flagsChanged, kVK_Command, [.maskControl, .maskAlternate, .maskCommand])
check(heldCycle.mode == .cycle, "adding Command preserves custom cycle")
check(heldCycle.synthetic(.keyDown, kVK_ANSI_3, [.maskControl, .maskAlternate, .maskCommand]), "Command with held invocation modifiers selects cycle result")
check(heldCycle.mode == .hidden, "custom cycle direct selection commits")

for (modifier, aggregate, side, _) in modifierCases {
    let heldFast = KeyboardController()
    heldFast.configuration.fastSearchModifier = modifier
    heldFast.loadSyntheticLayout()
    _ = heldFast.synthetic(.flagsChanged, kVK_Function)
    let heldFlags = aggregate.union(CGEventFlags(rawValue: side))
    check(heldFast.synthetic(.keyDown, kVK_ANSI_A, heldFlags), "Fast Search opens for direct selection with \(modifier)")
    heldFast.resultCount = 3
    let selectionFlags = heldFlags.union(.maskCommand)
    _ = heldFast.synthetic(.flagsChanged, kVK_Command, selectionFlags)
    check(heldFast.mode == .fastSearch, "Command preserves held \(modifier) while awaiting number")
    check(heldFast.synthetic(.keyDown, kVK_ANSI_9, selectionFlags), "invalid held-modifier number is consumed")
    check(heldFast.mode == .fastSearch, "invalid number keeps Fast Search open with \(modifier)")
    check(heldFast.synthetic(.keyDown, kVK_ANSI_3, selectionFlags), "Command plus held \(modifier) selects result")
    check(heldFast.mode == .hidden, "direct selection commits Fast Search with \(modifier)")
    check(heldFast.synthetic(.keyUp, kVK_ANSI_3), "held-modifier selection owns keyup for \(modifier)")
}
flush()
print("PASS: Cmd1-9 direct selection, bounds/precedence/repeats/buffering/stale-query safety, configured chords, seven Fast Search modifiers, resume safety, Unicode buffering, and 100 search-opening races")
