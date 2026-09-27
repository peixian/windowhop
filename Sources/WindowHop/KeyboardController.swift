import AppKit
import Carbon
import WindowHopCore

enum KeyboardAction {
    case beginCycle(reverse: Bool)
    case cycle(reverse: Bool)
    case showSearch
    case beginFastSearch(String)
    case appendText(String)
    case deleteBackward
    case move(Int)
    case selectAndCommit(Int)
    case commit
    case cancel
}

/// The tap runs on the main run loop. Its callback only updates local state;
/// UI actions are delivered in order after the callback returns.
final class KeyboardController {
    enum Mode { case hidden, cycle, search, fastSearch }

    var onAction: ((KeyboardAction) -> Void)?
    var onFailure: ((String) -> Void)?
    var resultCount = 0
    var configuration: ShortcutConfiguration = .defaults {
        didSet {
            guard oldValue != configuration else { return }
            generation += 1
            if mode != .hidden { finish(.cancel) }
            suppressFastSearchUntilRelease = true
            fastModifierHeld = false
            configurationIsValid = configuration.validationError() == nil
            if let error = configuration.validationError() { reportFailure(error) }
        }
    }
    var commandTabEnabled: Bool {
        get { configuration.cycleEnabled }
        set { configuration.cycleEnabled = newValue }
    }
    var fastSearchModifier: FastSearchModifier {
        get { configuration.fastSearchModifier }
        set { configuration.fastSearchModifier = newValue }
    }
    var mode: Mode = .hidden {
        didSet {
            searchSession += 1
            resultCount = 0
            if mode != .cycle { cycleHoldModifiers = 0 }
            if mode != .search {
                preparingSearch = false
                pendingSearchEvents.removeAll()
                pendingSearchKeys.removeAll()
                replayedSearchKeyUps.removeAll()
            }
            if mode == .hidden {
                deadKeyState = 0
                if oldValue == .fastSearch, fastModifierHeld {
                    suppressFastSearchUntilRelease = true
                }
            }
        }
    }
    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    private var configurationIsValid = true
    private var cycleHoldModifiers: UInt64 = 0
    private static let chordModifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var layoutObserver: NSObjectProtocol?
    private var secureInputTimer: Timer?
    private var layoutData: CFData?
    private var deadKeyState: UInt32 = 0
    private var consumedKeys = Set<CGKeyCode>()
    private var fastModifierHeld = false
    private var suppressFastSearchUntilRelease = false
    private var secureInputWasEnabled = false
    private var generation = 0
    private var searchSession = 0
    private var preparingSearch = false
    private var pendingSearchEvents: [CGEvent] = []
    private var pendingSearchKeys = Set<CGKeyCode>()
    private var replayedSearchKeyUps: [CGKeyCode: (session: Int, window: Int)] = [:]
    private var searchBufferOverflowed = false

    /// Call after the native search field becomes first responder. Early input
    /// is delivered only to this application's field, never posted globally.
    func searchFieldReady() {
        precondition(Thread.isMainThread)
        guard mode == .search, preparingSearch else { return }
        guard let window = NSApp.keyWindow else {
            finish(.cancel)
            reportFailure("Search could not receive keyboard focus. Please try again.")
            return
        }
        completeSearchPreparation(windowNumber: window.windowNumber) { NSApp.sendEvent($0) }
    }

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        if eventTap != nil { return isRunning }
        if let error = configuration.validationError() { reportFailure(error); return false }
        cacheKeyboardLayout()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<KeyboardController>.fromOpaque(info).takeUnretainedValue()
                return controller.filter(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            reportFailure(IsSecureEventInputEnabled()
                ? "Secure Keyboard Entry is active. Keyboard shortcuts will be available after it ends."
                : "Keyboard capture could not start. Allow WindowHop in Accessibility settings, then retry.")
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.cacheKeyboardLayout() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSecureInput()
        }
        secureInputTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        checkSecureInput()
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        let wasVisible = mode != .hidden
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let layoutObserver {
            DistributedNotificationCenter.default().removeObserver(layoutObserver)
        }
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        layoutObserver = nil
        runLoopSource = nil
        eventTap = nil
        consumedKeys.removeAll()
        mode = .hidden
        fastModifierHeld = false
        suppressFastSearchUntilRelease = false
        if wasVisible { emit(.cancel) }
    }

    deinit {
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let layoutObserver {
            DistributedNotificationCenter.default().removeObserver(layoutObserver)
        }
        secureInputTimer?.invalidate()
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if mode != .hidden { finish(.cancel) }
            consumedKeys.removeAll()
            suppressFastSearchUntilRelease = true
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            reportFailure("Keyboard capture was interrupted. The current switch was cancelled and capture restarted.")
            return Unmanaged.passUnretained(event)
        }

        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        fastModifierHeld = isFastModifierHeld(flags)
        if !fastModifierHeld { suppressFastSearchUntilRelease = false }
        // Reconcile on every event in case macOS omitted a modifier transition.
        if mode == .cycle, flags.rawValue & cycleHoldModifiers != cycleHoldModifiers { finish(.commit) }
        if mode == .fastSearch {
            if !fastModifierHeld { finish(.commit) }
            else if !fastSearchFlagsAllowed(flags, key: key), !quickSelectionModifiersAllowed(flags) { finish(.cancel) }
        }

        if type == .keyUp {
            if mode == .search, preparingSearch, pendingSearchKeys.remove(key) != nil {
                bufferSearchEvent(event)
                consumedKeys.remove(key)
                return nil
            }
            if let replay = replayedSearchKeyUps.removeValue(forKey: key), let copy = event.copy() {
                consumedKeys.remove(key)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.mode == .search, self.searchSession == replay.session,
                          let native = self.nativeSearchEvent(copy, windowNumber: replay.window) else { return }
                    NSApp.sendEvent(native)
                }
                return nil
            }
            return consumedKeys.remove(key) != nil ? nil : Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if mode == .hidden, consumedKeys.contains(key), isRepeat {
            return consume(key)
        }

        let reversed = flags.contains(.maskShift)

        if mode != .hidden, let index = directSelectionIndex(key: key, flags: flags) {
            if mode == .search, !preparingSearch,
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return Unmanaged.passUnretained(event)
            }
            if mode == .search, preparingSearch {
                pendingSearchKeys.insert(key)
                bufferSearchEvent(event)
            } else if !isRepeat, index < resultCount {
                finish(.selectAndCommit(index))
            }
            return consume(key)
        }

        if configurationIsValid, configuration.cycleEnabled,
           matches(configuration.cycle, key: key, flags: flags, allowingReverse: true) {
            if mode != .cycle, isRepeat { return consume(key) }
            if mode == .cycle {
                emit(.cycle(reverse: reversed))
            } else {
                mode = .cycle
                cycleHoldModifiers = configuration.cycle.modifiers.rawValue & ~CGEventFlags.maskShift.rawValue
                emit(.beginCycle(reverse: reversed))
            }
            return consume(key)
        }
        if configurationIsValid, configuration.searchEnabled, matches(configuration.search, key: key, flags: flags) {
            if mode != .search, isRepeat { return consume(key) }
            if mode != .search {
                mode = .search
                preparingSearch = true
                searchBufferOverflowed = false
                pendingSearchEvents.removeAll()
                pendingSearchKeys.removeAll()
                emit(.showSearch)
            }
            return consume(key)
        }

        if mode == .search, preparingSearch {
            pendingSearchKeys.insert(key)
            bufferSearchEvent(event)
            return consume(key)
        }

        if mode == .fastSearch, !fastSearchFlagsAllowed(flags, key: key) {
            finish(.cancel)
            return Unmanaged.passUnretained(event)
        }

        if mode != .hidden {
            // Let the native field's input method own its composition commands.
            if mode == .search, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
               editor.hasMarkedText() { return Unmanaged.passUnretained(event) }
            switch Int(key) {
            case kVK_Escape:
                finish(.cancel)
                return consume(key)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                finish(.commit)
                return consume(key)
            case kVK_UpArrow:
                emit(.move(-1))
                return consume(key)
            case kVK_DownArrow:
                emit(.move(1))
                return consume(key)
            case kVK_Tab:
                emit(.move(reversed ? -1 : 1))
                return consume(key)
            case kVK_Delete where mode == .fastSearch:
                deadKeyState = 0
                resultCount = 0
                emit(.deleteBackward)
                return consume(key)
            case kVK_LeftArrow where mode == .cycle:
                emit(.move(-1))
                return consume(key)
            case kVK_RightArrow where mode == .cycle:
                emit(.move(1))
                return consume(key)
            default: break
            }
        }

        if configurationIsValid, configuration.fastSearchEnabled,
           (mode == .hidden || mode == .fastSearch), fastModifierHeld,
           !suppressFastSearchUntilRelease, fastSearchFlagsAllowed(flags, key: key),
           let text = translatedText(key: key, flags: flags, event: event) {
            if mode == .hidden, isRepeat {
                deadKeyState = 0
                return consume(key)
            }
            if mode == .hidden {
                mode = .fastSearch
                emit(.beginFastSearch(text))
            } else if !text.isEmpty {
                resultCount = 0
                emit(.appendText(text))
            }
            return consume(key)
        }

        // An unrelated shortcut must not leave a later modifier release armed.
        if mode == .cycle || mode == .fastSearch {
            finish(.cancel)
        }
        return Unmanaged.passUnretained(event)
    }

    private func consume(_ key: CGKeyCode) -> Unmanaged<CGEvent>? {
        consumedKeys.insert(key)
        return nil
    }

    private func bufferSearchEvent(_ event: CGEvent) {
        guard pendingSearchEvents.count < 512, let copy = event.copy() else {
            searchBufferOverflowed = true
            return
        }
        pendingSearchEvents.append(copy)
    }

    private func completeSearchPreparation(windowNumber: Int, deliver: (NSEvent) -> Void) {
        guard mode == .search, preparingSearch else { return }
        let events = pendingSearchEvents
        let heldKeys = pendingSearchKeys
        let session = searchSession
        preparingSearch = false
        pendingSearchEvents.removeAll()
        pendingSearchKeys.removeAll()
        guard !searchBufferOverflowed else {
            finish(.cancel)
            reportFailure("Search took too long to open. Buffered input was discarded; please try again.")
            return
        }
        for event in events {
            guard mode == .search, searchSession == session else { break }
            guard let native = nativeSearchEvent(event, windowNumber: windowNumber) else {
                finish(.cancel)
                reportFailure("Search could not deliver buffered input. Please try again.")
                return
            }
            let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if event.type == .keyDown, heldKeys.contains(key) {
                replayedSearchKeyUps[key] = (session, windowNumber)
            }
            deliver(native)
        }
    }

    private func nativeSearchEvent(_ event: CGEvent, windowNumber: Int) -> NSEvent? {
        guard let source = NSEvent(cgEvent: event) else { return nil }
        return NSEvent.keyEvent(
            with: source.type, location: .zero, modifierFlags: source.modifierFlags,
            timestamp: source.timestamp, windowNumber: windowNumber, context: nil,
            characters: source.characters ?? "", charactersIgnoringModifiers: source.charactersIgnoringModifiers ?? "",
            isARepeat: source.isARepeat, keyCode: source.keyCode
        )
    }

    private func finish(_ action: KeyboardAction) {
        mode = .hidden
        emit(action)
    }

    private func emit(_ action: KeyboardAction) {
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.onAction?(action)
        }
    }

    private func reportFailure(_ message: String) {
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.onFailure?(message)
        }
    }

    private func matches(_ shortcut: KeyboardShortcut, key: CGKeyCode, flags: CGEventFlags, allowingReverse: Bool = false) -> Bool {
        guard key == shortcut.keyCode else { return false }
        let mask = Self.chordModifierMask & (allowingReverse ? ~CGEventFlags.maskShift.rawValue : UInt64.max)
        var actual = flags.rawValue
        if KeyboardShortcut.hasImplicitFunctionFlag(keyCode: key) { actual &= ~CGEventFlags.maskSecondaryFn.rawValue }
        return actual & mask == shortcut.modifiers.rawValue & mask
    }

    private func directSelectionIndex(key: CGKeyCode, flags: CGEventFlags) -> Int? {
        guard quickSelectionModifiersAllowed(flags) else { return nil }
        switch Int(key) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default: return nil
        }
    }

    private func quickSelectionModifiersAllowed(_ flags: CGEventFlags) -> Bool {
        var expected = CGEventFlags.maskCommand.rawValue
        if mode == .cycle { expected |= cycleHoldModifiers }
        if mode == .fastSearch {
            let bits = fastModifierBits
            guard flags.rawValue & bits.selected != 0, flags.rawValue & bits.opposite == 0 else { return false }
            expected |= bits.aggregate
        }
        return flags.rawValue & Self.chordModifierMask == expected
    }

    private var fastModifierBits: (aggregate: UInt64, selected: UInt64, opposite: UInt64) {
        switch fastSearchModifier {
        case .leftOption: return (CGEventFlags.maskAlternate.rawValue, 0x20, 0x40)
        case .rightOption: return (CGEventFlags.maskAlternate.rawValue, 0x40, 0x20)
        case .leftCommand: return (CGEventFlags.maskCommand.rawValue, 0x8, 0x10)
        case .rightCommand: return (CGEventFlags.maskCommand.rawValue, 0x10, 0x8)
        case .leftControl: return (CGEventFlags.maskControl.rawValue, 0x1, 0x2000)
        case .rightControl: return (CGEventFlags.maskControl.rawValue, 0x2000, 0x1)
        case .fn: return (CGEventFlags.maskSecondaryFn.rawValue, CGEventFlags.maskSecondaryFn.rawValue, 0)
        }
    }

    private func isFastModifierHeld(_ flags: CGEventFlags) -> Bool {
        let bits = fastModifierBits
        return flags.rawValue & bits.selected != 0 && flags.rawValue & bits.aggregate != 0
    }

    private func fastSearchFlagsAllowed(_ flags: CGEventFlags, key: CGKeyCode) -> Bool {
        let bits = fastModifierBits
        var mask = Self.chordModifierMask & ~CGEventFlags.maskShift.rawValue
        // Navigation keys carry the Fn bit even without the physical Fn key.
        if fastSearchModifier != .fn, KeyboardShortcut.hasImplicitFunctionFlag(keyCode: key) {
            mask &= ~CGEventFlags.maskSecondaryFn.rawValue
        }
        return flags.rawValue & mask == bits.aggregate && flags.rawValue & bits.opposite == 0
    }

    private func cacheKeyboardLayout() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            layoutData = nil
            return
        }
        layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        deadKeyState = 0
    }

    private func translatedText(key: CGKeyCode, flags: CGEventFlags, event: CGEvent) -> String? {
        guard let layoutData, let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        var count = 0
        var characters = [UniChar](repeating: 0, count: 16)
        let result = UCKeyTranslate(
            layout, key, UInt16(kUCKeyActionDown), modifiers,
            UInt32(event.getIntegerValueField(.keyboardEventKeyboardType)), 0,
            &deadKeyState, characters.count, &count, &characters
        )
        guard result == noErr else { return nil }
        if count == 0 { return deadKeyState != 0 ? "" : nil }
        let text = String(utf16CodeUnits: characters, count: count)
        guard text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }) else { return nil }
        return text
    }

    private func checkSecureInput() {
        let enabled = IsSecureEventInputEnabled()
        if enabled, !secureInputWasEnabled {
            if mode != .hidden { finish(.cancel) }
            consumedKeys.removeAll()
            suppressFastSearchUntilRelease = true
            reportFailure("Secure Keyboard Entry is active. WindowHop shortcuts resume when it ends.")
        }
        secureInputWasEnabled = enabled
    }
}
