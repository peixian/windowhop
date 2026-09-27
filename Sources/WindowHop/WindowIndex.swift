import AppKit
import ApplicationServices
import Darwin
import WindowHopCore

/// Discovery and focus have independent queues: unrelated apps cannot hold a
/// committed switch behind their discovery IPC. Main only reads cached snapshots.
final class WindowIndex {
    var onChange: (([WindowItem]) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var windows: [WindowItem] = []

    private struct Record {
        let id: String
        let pid: pid_t
        let element: AXUIElement
        let windowID: CGWindowID?
        let item: WindowItem
        let ordinal: UInt64
        var recency: UInt64
    }

    /// An immutable snapshot, retained independently of the discovery dictionary.
    /// The AX reference is an opaque handle; its remote window may still disappear.
    private struct FocusTarget {
        let id: String
        let pid: pid_t
        let element: AXUIElement
        let windowID: CGWindowID?
        let generation: UUID

        func replacingElement(_ element: AXUIElement) -> FocusTarget {
            FocusTarget(id: id, pid: pid, element: element, windowID: windowID, generation: generation)
        }
    }

    private struct ApplicationObserver {
        let observer: AXObserver
        let application: AXUIElement
        var windows: [String: AXUIElement]
    }

    enum FocusError: LocalizedError {
        case unavailable, permission, notFocused, superseded
        var errorDescription: String? {
            switch self {
            case .unavailable: return "That window is no longer available."
            case .permission: return "WindowHop needs Accessibility access to switch windows."
            case .notFocused: return "macOS did not focus the selected window. Try again; a dialog or another Space may be blocking it."
            case .superseded: return "The window switch was cancelled by a newer request."
            }
        }
    }

    private let worker = DispatchQueue(label: "dog.malloc.windowhop.discovery", qos: .utility)
    private let focusWorker = DispatchQueue(label: "dog.malloc.windowhop.focus", qos: .userInitiated)
    private var records: [String: Record] = [:]
    private var focusRecords: [String: FocusTarget] = [:] // Main queue only.
    private var observers: [pid_t: ApplicationObserver] = [:]
    private var timer: DispatchSourceTimer?
    private var workspaceTokens: [NSObjectProtocol] = [] // Main queue only.
    private var mainGeneration = UUID() // Main queue only.
    private var generation = UUID() // Worker only.
    private var running = false
    private var scanQueued = false
    private var scanning = false
    private var scanAgain = false
    private var scanOffsets: [pid_t: Int] = [:]
    private var ordinal: UInt64 = 0
    private var recency: UInt64 = 0
    private var focusedID: String?
    // The main queue writes this token immediately, without waiting for AX IPC.
    // The lock protects only the token; no AppKit or AX call runs while held.
    private let activationLock = NSLock()
    private var activationRequest: UUID?
    private var lastStatus = ""
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let axTimeout: Float = 0.12

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard workspaceTokens.isEmpty else { return }
        let token = UUID()
        mainGeneration = token
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.worker.async { [weak self] in
                guard let self, self.running else { return }
                self.observeFocusedWindow(pid: pid)
                self.scheduleScan()
            }
        })
        worker.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.generation = token
            self.lastStatus = ""
            // The system-wide element sets the default for this process only;
            // returned/notification AX references otherwise inherit a long timeout.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), self.axTimeout)
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now() + 4, repeating: 4, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.scheduleScan() }
            self.timer = timer
            timer.resume()
            self.scheduleScan(delay: 0)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelPendingActivation()
        mainGeneration = UUID()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        worker.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.scanQueued = false
            self.scanning = false
            self.scanAgain = false
            self.scanOffsets.removeAll()
            for pid in Array(self.observers.keys) { self.removeObserver(pid: pid) }
            self.records.removeAll()
            self.focusedID = nil
        }
        windows = []
        focusRecords.removeAll()
        onChange?([])
    }

    func refresh() {
        worker.async { [weak self] in self?.scheduleScan() }
    }

    private func scheduleScan(delay: TimeInterval = 0.10) {
        guard running else { return }
        if scanning { scanAgain = true; return }
        guard !scanQueued else { return }
        scanQueued = true
        let token = generation
        worker.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.scanQueued = false
            self.beginScan()
        }
    }

    private func beginScan() {
        guard AXIsProcessTrusted() else {
            records.removeAll()
            for pid in Array(observers.keys) { removeObserver(pid: pid) }
            publish()
            status("Accessibility access is required to discover and switch windows.")
            return
        }
        scanning = true
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        records = records.filter { livePIDs.contains($0.value.pid) }
        scanOffsets = scanOffsets.filter { livePIDs.contains($0.key) }
        for pid in Array(observers.keys) where !livePIDs.contains(pid) { removeObserver(pid: pid) }
        scan(apps, at: 0, token: generation)
    }

    /// Yield between applications so observer work can interleave with discovery.
    /// Focus uses a separate queue and never waits for this scan to yield.
    private func scan(_ apps: [NSRunningApplication], at index: Int, token: UUID) {
        guard running, generation == token else { return }
        guard index < apps.count else {
            scanning = false
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                observeFocusedWindow(pid: pid, shouldPublish: false)
            }
            publish()
            status("\(records.count) windows available. Other Spaces are best effort.")
            if scanAgain { scanAgain = false; scheduleScan() }
            return
        }
        scanApplication(apps[index])
        worker.async { [weak self] in self?.scan(apps, at: index + 1, token: token) }
    }

    private func scanApplication(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, axTimeout)
        ensureObserver(pid: pid, application: application)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let elements = value as? [AXUIElement] else { return }
        let name = app.localizedName ?? "Application"
        // Enumeration succeeded, so references absent from this list can be
        // discarded even when attribute reads are split across reconciliations.
        let removed = records.values.filter { record in
            record.pid == pid && !elements.contains(where: { CFEqual($0, record.element) })
        }.map(\.id)
        for id in removed { records.removeValue(forKey: id); removeWindowObservation(id: id, pid: pid) }
        let offset = min(scanOffsets[pid] ?? 0, max(0, elements.count - 1))
        scanOffsets[pid] = 0
        let start = ProcessInfo.processInfo.systemUptime
        // A broken app must not monopolize the serial queue. Large healthy apps
        // are normally below this bound; resume after the last inspected element.
        for position in offset..<elements.count {
            if ProcessInfo.processInfo.systemUptime - start > 0.65 {
                scanOffsets[pid] = position
                break
            }
            let element = elements[position]
            AXUIElementSetMessagingTimeout(element, axTimeout)
            let (id, windowID) = identity(element, pid: pid)
            let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
                  let attributes = values as? [Any], attributes.count == 4 else { continue }
            guard let role = attributes[0] as? String else { continue }
            guard role == kAXWindowRole else {
                records.removeValue(forKey: id)
                removeWindowObservation(id: id, pid: pid)
                continue
            }
            let subrole = attributes[1] as? String
            guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
                records.removeValue(forKey: id)
                removeWindowObservation(id: id, pid: pid)
                continue
            }
            let title = attributes[2] as? String ?? ""
            let minimized = (attributes[3] as? NSNumber)?.boolValue ?? false
            let previous = records[id]
            if previous == nil { ordinal &+= 1 }
            let item = WindowItem(id: id, appName: name, title: title,
                                  bundleIdentifier: app.bundleIdentifier ?? "",
                                  isMinimized: minimized, isHidden: app.isHidden)
            records[id] = Record(id: id, pid: pid, element: element, windowID: windowID, item: item,
                                 ordinal: previous?.ordinal ?? ordinal, recency: previous?.recency ?? 0)
            observeWindow(id: id, pid: pid, element: element)
        }
    }

    private func identity(_ element: AXUIElement, pid: pid_t) -> (String, CGWindowID?) {
        if let number = WindowIDBridge.number(of: element) { return ("\(pid):\(number)", number) }
        if let existing = records.values.first(where: { $0.pid == pid && CFEqual($0.element, element) }) {
            return (existing.id, existing.windowID)
        }
        return ("\(pid):ax:\(UUID().uuidString)", nil)
    }

    private func ensureObserver(pid: pid_t, application: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let index = Unmanaged<WindowIndex>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            // Notification delivery itself performs no cross-process requests.
            index.worker.async { [weak index] in index?.handleNotification(element, name: name) }
        }, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, application, name as CFString, context)
        }
        observers[pid] = ApplicationObserver(observer: observer, application: application, windows: [:])
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func observeWindow(id: String, pid: pid_t, element: AXUIElement) {
        guard var entry = observers[pid] else { return }
        if let current = entry.windows[id], CFEqual(current, element) { return }
        if entry.windows[id] != nil { removeWindowObservation(id: id, pid: pid); entry = observers[pid]! }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(entry.observer, element, name as CFString, context)
        }
        entry.windows[id] = element
        observers[pid] = entry
    }

    private func removeWindowObservation(id: String, pid: pid_t) {
        guard var entry = observers[pid], let element = entry.windows.removeValue(forKey: id) else { return }
        for name in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverRemoveNotification(entry.observer, element, name as CFString)
        }
        observers[pid] = entry
    }

    private func removeObserver(pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
    }

    private func handleNotification(_ element: AXUIElement, name: String) {
        guard running else { return }
        if name == kAXUIElementDestroyedNotification {
            if let record = records.values.first(where: { CFEqual($0.element, element) }) {
                records.removeValue(forKey: record.id)
                removeWindowObservation(id: record.id, pid: record.pid)
                if focusedID == record.id { focusedID = nil }
                publish()
            }
        } else if name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { observeFocusedWindow(pid: pid) }
        }
        scheduleScan()
    }

    private func observeFocusedWindow(pid: pid_t, shouldPublish: Bool = true) {
        guard pid != ownPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let element = focusedWindow(in: app),
              let record = matchingRecord(element, pid: pid), record.id != focusedID else { return }
        focusedID = record.id
        recency &+= 1
        records[record.id]?.recency = recency
        if shouldPublish { publish() }
    }

    private func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }

    private func matchingRecord(_ element: AXUIElement, pid: pid_t) -> Record? {
        if let number = WindowIDBridge.number(of: element), let record = records["\(pid):\(number)"] { return record }
        return records.values.first { $0.pid == pid && CFEqual($0.element, element) }
    }

    private func publish() {
        let items = records.values.sorted {
            $0.recency == $1.recency ? $0.ordinal < $1.ordinal : $0.recency > $1.recency
        }.map(\.item)
        let token = generation
        let targets = records.mapValues {
            FocusTarget(id: $0.id, pid: $0.pid, element: $0.element, windowID: $0.windowID, generation: token)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainGeneration == token else { return }
            self.windows = items
            self.focusRecords = targets
            self.onChange?(items)
        }
    }

    private func status(_ message: String) {
        guard message != lastStatus else { return }
        lastStatus = message
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainGeneration == token else { return }
            self.onStatus?(message)
        }
    }

    /// Invalidate queued work and later retries immediately. Cancellation is best
    /// effort at each check/call boundary: a call racing that check or already sent
    /// to another process cannot be recalled. Subsequent operations recheck the
    /// token, and a stale completion cannot report success.
    func cancelPendingActivation() {
        dispatchPrecondition(condition: .onQueue(.main))
        activationLock.lock()
        activationRequest = nil
        activationLock.unlock()
    }

    private func isCurrentActivation(_ request: UUID) -> Bool {
        activationLock.lock()
        defer { activationLock.unlock() }
        return activationRequest == request
    }

    private func finishFocus(_ request: UUID, result: Result<Void, Error>,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentActivation(request) else {
                completion(.failure(FocusError.superseded))
                return
            }
            completion(result)
        }
    }

    private func continueFocus(_ request: UUID, completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        // Never read discovery-owned `running` or `records` from the focus queue.
        // stop() invalidates this token synchronously before queuing index cleanup.
        guard isCurrentActivation(request) else {
            finishFocus(request, result: .failure(FocusError.superseded), completion: completion)
            return false
        }
        return true
    }

    func activate(_ item: WindowItem, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = UUID()
        activationLock.lock()
        activationRequest = request
        activationLock.unlock()
        // Constant-time main-owned snapshot lookup; no discovery queue hop and no
        // AX request on the keyboard/main thread, even while another app is hung.
        guard let record = focusRecords[item.id] else {
            finishFocus(request, result: .failure(FocusError.unavailable), completion: completion)
            return
        }
        focusWorker.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.failure(FocusError.unavailable)) }
                return
            }
            guard self.continueFocus(request, completion: completion) else { return }
            guard AXIsProcessTrusted() else {
                self.clearFocusSnapshotAfterPermissionLoss(generation: record.generation)
                self.finishFocus(request, result: .failure(FocusError.permission), completion: completion)
                return
            }
            self.focus(record, request: request, attempt: 0, completion: completion)
        }
    }

    private func focus(_ record: FocusTarget, request: UUID, attempt: Int,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        guard continueFocus(request, completion: completion) else { return }
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else {
            finishFocus(request, result: .failure(FocusError.unavailable), completion: completion)
            return
        }
        AXUIElementSetMessagingTimeout(record.element, axTimeout)
        guard continueFocus(request, completion: completion) else { return }
        let unminimize = AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard acceptFocusResult(unminimize, record: record, app: app, request: request,
                                attempt: attempt, completion: completion),
              continueFocus(request, completion: completion) else { return }
        let makeMain = AXUIElementSetAttributeValue(record.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard acceptFocusResult(makeMain, record: record, app: app, request: request,
                                attempt: attempt, completion: completion),
              continueFocus(request, completion: completion) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(.failure(FocusError.unavailable)); return }
            guard self.isCurrentActivation(request) else { completion(.failure(FocusError.superseded)); return }
            guard !app.isTerminated else { completion(.failure(FocusError.unavailable)); return }
            app.unhide()
            guard self.isCurrentActivation(request) else { completion(.failure(FocusError.superseded)); return }
            app.activate(options: [.activateIgnoringOtherApps])
            self.focusWorker.async { [weak self] in
                guard let self else { return }
                guard self.continueFocus(request, completion: completion) else { return }
                let raise = AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
                guard self.acceptFocusResult(raise, record: record, app: app, request: request,
                                            attempt: attempt, completion: completion),
                      self.continueFocus(request, completion: completion) else { return }
                self.focusWorker.asyncAfter(deadline: .now() + (attempt == 0 ? 0.12 : 0.25)) { [weak self] in
                    guard let self else { return }
                    guard self.continueFocus(request, completion: completion) else { return }
                    let didFocus = self.isFocused(record)
                    guard self.continueFocus(request, completion: completion) else { return }
                    if didFocus {
                        self.reconcileAfterFocus(pid: record.pid, generation: record.generation)
                        self.finishFocus(request, result: .success(()), completion: completion)
                    } else if attempt == 0 {
                        self.retryFocus(record, app: app, request: request, completion: completion)
                    } else {
                        self.refresh()
                        self.finishFocus(request, result: .failure(FocusError.notFocused), completion: completion)
                    }
                }
            }
        }
    }

    /// Unsupported optional operations are harmless only if final verification
    /// proves focus. A destroyed reference must never cause app-only activation.
    private func acceptFocusResult(_ result: AXError, record: FocusTarget, app: NSRunningApplication,
                                   request: UUID, attempt: Int,
                                   completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard continueFocus(request, completion: completion) else { return false }
        switch result {
        case .success, .attributeUnsupported, .actionUnsupported, .notImplemented:
            return true
        case .invalidUIElement:
            refresh()
            finishFocus(request, result: .failure(FocusError.unavailable), completion: completion)
        case .apiDisabled:
            clearFocusSnapshotAfterPermissionLoss(generation: record.generation)
            finishFocus(request, result: .failure(FocusError.permission), completion: completion)
        case .cannotComplete where attempt == 0:
            retryFocus(record, app: app, request: request, completion: completion)
        default:
            finishFocus(request, result: .failure(FocusError.notFocused), completion: completion)
        }
        return false
    }

    private func retryFocus(_ record: FocusTarget, app: NSRunningApplication, request: UUID,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard continueFocus(request, completion: completion) else { return }
        focusWorker.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard self.continueFocus(request, completion: completion) else { return }
            guard !app.isTerminated else {
                self.finishFocus(request, result: .failure(FocusError.unavailable), completion: completion)
                return
            }
            // Re-resolve only the target application's exact window. Never run
            // discovery or consult its mutable cache on the focus path.
            let resolved = self.resolveFocusTarget(record, request: request)
            guard self.continueFocus(request, completion: completion) else { return }
            switch resolved {
            case .success(let fresh):
                self.focus(fresh, request: request, attempt: 1, completion: completion)
            case .failure(let error):
                if case .permission = error { self.clearFocusSnapshotAfterPermissionLoss(generation: record.generation) }
                self.refresh()
                self.finishFocus(request, result: .failure(error), completion: completion)
            }
        }
    }

    private func resolveFocusTarget(_ target: FocusTarget, request: UUID) -> Result<FocusTarget, FocusError> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        guard isCurrentActivation(request) else { return .failure(.superseded) }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, axTimeout)
        if let focused = focusedWindow(in: application), matchesFocusTarget(focused, target: target) {
            return .success(target.replacingElement(focused))
        }
        guard isCurrentActivation(request) else { return .failure(.superseded) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let elements = value as? [AXUIElement] else {
            return .failure(result == .apiDisabled ? .permission : .unavailable)
        }
        guard isCurrentActivation(request) else { return .failure(.superseded) }
        // Compare retained identities locally before making any per-window calls.
        if let equal = elements.first(where: { CFEqual($0, target.element) }) {
            AXUIElementSetMessagingTimeout(equal, axTimeout)
            return .success(target.replacingElement(equal))
        }
        guard target.windowID != nil else { return .failure(.unavailable) }
        // AX node replacement can preserve a WindowServer ID. This exceptional
        // retry is bounded, and can wait only on the selected app, never other apps.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        for element in elements {
            guard isCurrentActivation(request) else { return .failure(.superseded) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .failure(.notFocused) }
            AXUIElementSetMessagingTimeout(element, axTimeout)
            if WindowIDBridge.number(of: element) == target.windowID {
                return .success(target.replacingElement(element))
            }
        }
        return .failure(.unavailable)
    }

    private func matchesFocusTarget(_ element: AXUIElement, target: FocusTarget) -> Bool {
        if CFEqual(element, target.element) { return true }
        // The expected ID was cached at discovery; don't query the old node again.
        guard let expected = target.windowID else { return false }
        return WindowIDBridge.number(of: element) == expected
    }

    private func isFocused(_ record: FocusTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.pid else { return false }
        let app = AXUIElementCreateApplication(record.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let focused = focusedWindow(in: app) else { return false }
        return matchesFocusTarget(focused, target: record)
    }

    private func reconcileAfterFocus(pid: pid_t, generation token: UUID) {
        worker.async { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.observeFocusedWindow(pid: pid)
            self.scheduleScan()
        }
    }

    private func clearFocusSnapshotAfterPermissionLoss(generation token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainGeneration == token else { return }
            self.focusRecords.removeAll()
            self.windows = []
            self.onChange?([])
            self.onStatus?("Accessibility access is required to discover and switch windows.")
        }
    }
}

/// The only private API in the index. This maps an already-accessible element to
/// an identity; it cannot enumerate missing windows or change focus. If unavailable,
/// the index retains identities by CFEqual comparison of Accessibility references.
private enum WindowIDBridge {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let function: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
    static func number(of element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var number: CGWindowID = 0
        return function(element, &number) == .success && number != 0 ? number : nil
    }
}
