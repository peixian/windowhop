import AppKit
import WindowHopCore

/// Optional physical trackpad-edge switching. All private MultitouchSupport
/// symbols and ABI assumptions are isolated here; nothing is installed or linked
/// into the app at build time. See docs/CONTEXTS-PARITY.md for the public API limit.
final class TrackpadGestureController {
    var onBegin: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var status = "Trackpad gesture is off."
    private(set) var isAvailable = false
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { stop() }
        }
    }

    private let lock = NSLock()
    private var states: [UInt: TrackpadGestureState] = [:]
    private var running = false
    private var generation = 0
    private var lastFrameTime = 0.0
    private var owningDevice: UInt?
    private var momentumDeadline = 0.0
    private var ownsScrollSequence = false
    private var suppressedEscape = false
    private var devices: [UnsafeMutableRawPointer] = []
    private var retainedDevices: CFArray?
    private var symbols: Symbols?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?

    /// Cancel the current gesture without calling onCancel. Root uses this when
    /// another invocation owns the switcher. Pending callbacks become obsolete.
    func cancel() {
        precondition(Thread.isMainThread)
        lock.lock()
        generation += 1
        for key in Array(states.keys) { _ = states[key]?.cancel() }
        lock.unlock()
    }

    private func start() {
        precondition(Thread.isMainThread)
        guard let api = Symbols() else {
            status = "Physical trackpad contacts are unavailable on this macOS version."
            return
        }
        guard let array = api.createList()?.takeRetainedValue() else {
            status = "No compatible trackpad was found."
            return
        }
        // Positive device-family matching excludes Magic Mouse and Touch Bar.
        // Unknown hardware remains disabled instead of guessing its geometry.
        let supported: Set<Int32> = [98, 99, 100, 101, 102, 103, 104, 108, 109, 128, 129, 130]
        var found: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: pointer)
            var family: Int32 = 0
            if api.family(device, &family) == 0, supported.contains(family) { found.append(device) }
        }
        guard !found.isEmpty else {
            status = "No supported MacBook or Magic Trackpad was found."
            return
        }
        let mask = [CGEventType.scrollWheel, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: mask,
                                            callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TrackpadGestureController>.fromOpaque(info).takeUnretainedValue().filter(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "Allow Accessibility access to use the trackpad gesture."
            return
        }
        symbols = api
        retainedDevices = array
        tap = newTap
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        lock.lock()
        generation += 1
        running = true
        states = Dictionary(uniqueKeysWithValues: found.map { (UInt(bitPattern: $0), TrackpadGestureState()) })
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        for device in found {
            ContactRouter.register(device, controller: self)
            api.register(device, rawContactCallback)
            if api.start(device, 0) == 0 {
                devices.append(device)
            } else {
                api.unregister(device, rawContactCallback)
                ContactRouter.unregister(device)
            }
        }
        guard !devices.isEmpty else {
            stop()
            status = "The trackpad contact stream could not start."
            return
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        isAvailable = true
        status = "Ready: two fingers down from either top corner of the trackpad."
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkStaleContacts() }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stop() {
        precondition(Thread.isMainThread)
        lock.lock()
        generation += 1
        running = false
        let wasActive = states.values.contains(where: \.isActive)
        states.removeAll()
        owningDevice = nil
        ownsScrollSequence = false
        momentumDeadline = 0
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        watchdog?.invalidate()
        watchdog = nil
        tap = nil
        source = nil
        if let symbols {
            for device in devices {
                ContactRouter.unregister(device)
                _ = symbols.stop(device)
                symbols.unregister(device, rawContactCallback)
            }
        }
        devices.removeAll()
        retainedDevices = nil
        symbols = nil
        suppressedEscape = false
        isAvailable = false
        status = "Trackpad gesture is off."
        if wasActive { onCancel?() }
    }

    deinit {
        // Root owns this object for the application's lifetime. Explicit disable
        // performs full cleanup; weak callback routing prevents stale dereferences.
        watchdog?.invalidate()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let symbols {
            for device in devices {
                ContactRouter.unregister(device)
                _ = symbols.stop(device)
                symbols.unregister(device, rawContactCallback)
            }
        }
    }

    fileprivate func receive(device: UnsafeMutableRawPointer, bytes: UnsafeRawPointer?, count: Int32, timestamp: Double) {
        // Current 64-bit MTContact ABI: 96-byte records, id/state at 16/20,
        // normalized x/y at 32/36. Definitions verified against Subsurface's
        // MTContact; implementation is independent.
        // https://github.com/mrkai77/Subsurface/blob/main/Sources/Subsurface/Touch/MTContact.swift
        guard count >= 0, count <= 16, timestamp.isFinite, count == 0 || bytes != nil else {
            invalidateStream()
            return
        }
        var contacts: [TrackpadGestureState.Contact] = []
        contacts.reserveCapacity(Int(count))
        if let bytes {
            for index in 0..<Int(count) {
                let record = bytes.advanced(by: index * 96)
                let id = record.loadUnaligned(fromByteOffset: 16, as: Int32.self)
                let state = record.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                let x = record.loadUnaligned(fromByteOffset: 32, as: Float.self)
                let y = record.loadUnaligned(fromByteOffset: 36, as: Float.self)
                guard (0...7).contains(state), x.isFinite, y.isFinite,
                      (-0.1...1.1).contains(x), (-0.1...1.1).contains(y) else {
                    invalidateStream()
                    return
                }
                if state == 3 || state == 4 {
                    contacts.append(.init(id: id, x: Double(x), y: Double(y)))
                }
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let deviceID = UInt(bitPattern: device)
        guard running, var state = states[deviceID] else { return }
        if let owningDevice, owningDevice != deviceID { state.unownedScrollDidPass() }
        let oldOwnership = state.ownsScroll
        let actions = state.update(contacts: contacts, timestamp: timestamp)
        states[deviceID] = state
        if state.ownsScroll && owningDevice == nil { owningDevice = deviceID }
        let now = ProcessInfo.processInfo.systemUptime
        if owningDevice == nil || owningDevice == deviceID { lastFrameTime = now }
        if oldOwnership && !state.ownsScroll {
            momentumDeadline = now + 0.8
            if owningDevice == deviceID { owningDevice = nil }
        }
        deliver(actions, generation: generation)
    }

    private func invalidateStream() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        generation += 1
        let active = states.values.contains(where: \.isActive)
        states.removeAll()
        owningDevice = nil
        ownsScrollSequence = false
        momentumDeadline = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stop()
            self.status = "Trackpad data was incompatible; gesture capture stopped."
            if active { self.onCancel?() }
        }
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelWithNotification()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 53, suppressedEscape {
            suppressedEscape = false
            return nil
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53, suppressedEscape { return nil }
        lock.lock()
        let active = states.values.contains(where: \.isActive)
        let capturing = states.values.contains(where: \.ownsScroll)
        lock.unlock()
        if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
            if capturing {
                cancelWithNotification()
                if active, type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    suppressedEscape = true
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            return Unmanaged.passUnretained(event)
        }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        lock.lock()
        defer { lock.unlock() }
        guard running else { return Unmanaged.passUnretained(event) }
        let ownsContact = states.values.contains(where: \.ownsScroll)
        let now = ProcessInfo.processInfo.systemUptime
        // A fresh normal gesture terminates momentum ownership immediately.
        if phase & Int64(CGScrollPhase.began.rawValue | CGScrollPhase.mayBegin.rawValue) != 0 && !ownsContact {
            ownsScrollSequence = false
            momentumDeadline = 0
        }
        let suppress = ownsContact || (ownsScrollSequence && (phase != 0 || momentum != 0) && now < momentumDeadline)
        if suppress {
            ownsScrollSequence = true
            momentumDeadline = now + 0.8
            if momentum == Int64(CGMomentumScrollPhase.end.rawValue) { ownsScrollSequence = false; momentumDeadline = 0 }
            return nil
        }
        if momentum == 0, phase == 0 || phase & Int64(CGScrollPhase.began.rawValue | CGScrollPhase.changed.rawValue) != 0 {
            for key in Array(states.keys) { states[key]?.unownedScrollDidPass() }
        }
        return Unmanaged.passUnretained(event)
    }

    private func cancelWithNotification() {
        lock.lock()
        var actions: [TrackpadGestureState.Action] = []
        for key in Array(states.keys) { actions.append(contentsOf: states[key]?.cancel() ?? []) }
        deliver(actions, generation: generation)
        lock.unlock()
    }

    private func checkStaleContacts() {
        lock.lock()
        let stale = states.values.contains(where: \.ownsScroll) && ProcessInfo.processInfo.systemUptime - lastFrameTime > 0.75
        let active = states.values.contains(where: \.isActive)
        if stale {
            generation += 1
            states = states.mapValues { _ in TrackpadGestureState() }
            owningDevice = nil
            ownsScrollSequence = false
            momentumDeadline = 0
        }
        lock.unlock()
        if stale && active { onCancel?() }
    }

    /// Called with the state lock held; scheduling under the lock retains callback
    /// order across contact and event-tap threads without running UI work there.
    private func deliver(_ actions: [TrackpadGestureState.Action], generation expected: Int) {
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == expected && self.running
            self.lock.unlock()
            guard current else { return }
            for action in actions {
                switch action {
                case .begin: self.onBegin?()
                case .move(let delta): self.onMove?(delta)
                case .commit: self.onCommit?()
                case .cancel: self.onCancel?()
                }
            }
        }
    }
}

private typealias RawContactCallback = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
private let rawContactCallback: RawContactCallback = { device, bytes, count, timestamp, _ in
    ContactRouter.controller(for: device)?.receive(device: device, bytes: bytes, count: count, timestamp: timestamp)
    return 0
}

private enum ContactRouter {
    private final class WeakController {
        weak var value: TrackpadGestureController?
        init(_ value: TrackpadGestureController) { self.value = value }
    }
    private static let lock = NSLock()
    private static var controllers: [UInt: WeakController] = [:]
    static func register(_ device: UnsafeMutableRawPointer, controller: TrackpadGestureController) {
        lock.lock(); defer { lock.unlock() }
        controllers[UInt(bitPattern: device)] = WeakController(controller)
    }
    static func unregister(_ device: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        controllers.removeValue(forKey: UInt(bitPattern: device))
    }
    static func controller(for device: UnsafeMutableRawPointer) -> TrackpadGestureController? {
        lock.lock(); defer { lock.unlock() }
        return controllers[UInt(bitPattern: device)]?.value
    }
}

private final class Symbols {
    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let family: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
    let register: @convention(c) (UnsafeMutableRawPointer, RawContactCallback) -> Void
    let unregister: @convention(c) (UnsafeMutableRawPointer, RawContactCallback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32

    // The framework handle is deliberately process-lived: late callbacks must
    // never return into unloaded private code after capture has stopped.
    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LOCAL | RTLD_LAZY)
    init?() {
        guard let handle = Self.handle else { return nil }
        func lookup<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let createList = lookup("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
              let family = lookup("MTDeviceGetFamilyID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self),
              let register = lookup("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, RawContactCallback) -> Void).self),
              let unregister = lookup("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, RawContactCallback) -> Void).self),
              let start = lookup("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
              let stop = lookup("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self) else { return nil }
        self.createList = createList
        self.family = family
        self.register = register
        self.unregister = unregister
        self.start = start
        self.stop = stop
    }
}
