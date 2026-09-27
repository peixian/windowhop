// Concatenated with TrackpadGestureController.swift. No live contacts are read,
// no global tap is installed, and no synthetic event is posted to the system.
extension TrackpadGestureController {
    func prepareSynthetic(device: UInt = 1) {
        running = true
        states[device] = TrackpadGestureState()
    }
    func contacts(_ points: [(Float, Float)], idOffset: Int32 = 0, device: UInt = 1) {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(1, points.count) * 96, alignment: 8)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: max(1, points.count) * 96)
        for (index, point) in points.enumerated() {
            let record = storage.advanced(by: index * 96)
            record.storeBytes(of: Int32(index + 1) + idOffset, toByteOffset: 16, as: Int32.self)
            record.storeBytes(of: Int32(4), toByteOffset: 20, as: Int32.self)
            record.storeBytes(of: point.0, toByteOffset: 32, as: Float.self)
            record.storeBytes(of: point.1, toByteOffset: 36, as: Float.self)
        }
        receive(device: UnsafeMutableRawPointer(bitPattern: device)!, bytes: storage, count: Int32(points.count), timestamp: ProcessInfo.processInfo.systemUptime)
    }
    func scroll(phase: Int64, momentum: Int64 = 0, continuous: Bool = true) -> Bool {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return filter(.scrollWheel, event) == nil
    }
    func key(_ code: CGKeyCode, down: Bool) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        return filter(down ? .keyDown : .keyUp, event) == nil
    }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
let gesture = TrackpadGestureController()
gesture.prepareSynthetic()
var actions: [String] = []
gesture.onBegin = { actions.append("begin") }
gesture.onMove = { actions.append("move\($0)") }
gesture.onCommit = { actions.append("commit") }
gesture.onCancel = { actions.append("cancel") }
gesture.contacts([(0.1, 0.96), (0.16, 0.95)])
check(gesture.scroll(phase: 1), "positively identified corner owns beginning of scroll")
check(!gesture.scroll(phase: 2, continuous: false), "discrete mouse wheel is never captured")
gesture.contacts([(0.1, 0.92), (0.16, 0.91)])
gesture.contacts([(0.1, 0.82), (0.16, 0.81)])
gesture.contacts([])
check(gesture.scroll(phase: 4), "owned scroll end suppressed after lift")
check(gesture.scroll(phase: 0, momentum: 1), "owned momentum begin suppressed")
check(gesture.scroll(phase: 0, momentum: 2), "owned momentum continuation suppressed")
check(gesture.scroll(phase: 0, momentum: 3), "owned momentum end suppressed")
check(!gesture.scroll(phase: 0, momentum: 2), "finished momentum no longer owned")
flush()
check(actions == ["begin", "move2", "commit"], "raw records produce ordered begin/move/commit")

gesture.contacts([])
gesture.contacts([(0.1, 0.96), (0.16, 0.95)])
_ = gesture.scroll(phase: 1)
gesture.contacts([(0.1, 0.92), (0.16, 0.91)])
check(gesture.key(53, down: true), "Escape cancels and does not reach underlying app")
check(gesture.key(53, down: true), "Escape repeat stays owned")
check(gesture.key(53, down: false), "Escape keyup is owned")
check(gesture.scroll(phase: 2), "cancelled owned gesture keeps scroll suppression until lift")
gesture.contacts([])
check(!gesture.scroll(phase: 1), "fresh ordinary scroll immediately drops stale momentum ownership")
flush()
check(actions.suffix(2) == ["begin", "cancel"], "Escape only cancels once")

gesture.contacts([])
gesture.contacts([(0.1, 0.96), (0.16, 0.95)])
gesture.contacts([(0.1, 0.92), (0.16, 0.91)])
gesture.cancel()
flush()
check(actions.suffix(2) == ["begin", "cancel"], "silent cancellation invalidates pending begin without extra callbacks")
gesture.contacts([])
flush()
check(actions.suffix(2) == ["begin", "cancel"], "silent cancellation does not commit later")

let ordinary = TrackpadGestureController()
ordinary.prepareSynthetic()
var ordinaryBegan = false
ordinary.onBegin = { ordinaryBegan = true }
check(!ordinary.scroll(phase: 1), "ordinary scroll is passed")
ordinary.contacts([(0.1, 0.96), (0.16, 0.95)])
ordinary.contacts([(0.1, 0.8), (0.16, 0.79)])
check(!ordinary.scroll(phase: 2), "late contact frame cannot steal started ordinary scroll")
ordinary.contacts([])
ordinary.contacts([(0.45, 0.96), (0.51, 0.95)])
ordinary.contacts([(0.45, 0.8), (0.51, 0.79)])
check(!ordinary.scroll(phase: 1), "physical top center remains ordinary scrolling")
flush()
check(!ordinaryBegan, "ordinary scroll never opens switcher")
print("PASS: raw contact parsing, physical-corner recognition, scroll/momentum ownership, Escape pairing, silent cancellation, and ordinary-scroll protection")

let multiple = TrackpadGestureController()
multiple.prepareSynthetic(device: 1)
multiple.prepareSynthetic(device: 2)
var begins = 0
var commits = 0
multiple.onBegin = { begins += 1 }
multiple.onCommit = { commits += 1 }
multiple.contacts([(0.1, 0.96), (0.16, 0.95)], device: 1)
multiple.contacts([(0.1, 0.92), (0.16, 0.91)], device: 1)
multiple.contacts([(0.8, 0.96), (0.86, 0.95)], device: 2)
multiple.contacts([(0.8, 0.92), (0.86, 0.91)], device: 2)
multiple.contacts([], device: 1)
multiple.contacts([], device: 2)
flush()
check(begins == 1 && commits == 1, "only one trackpad may own a switching session")
multiple.cancel() // Root also calls silent cancel after committing a completed gesture.
multiple.contacts([(0.8, 0.96), (0.86, 0.95)], device: 2)
multiple.contacts([(0.8, 0.92), (0.86, 0.91)], device: 2)
multiple.contacts([], device: 2)
flush()
check(begins == 2 && commits == 2, "second trackpad works after a fresh gesture")
print("PASS: multiple trackpads cannot start overlapping switching sessions")

let afterNormal = TrackpadGestureController()
afterNormal.prepareSynthetic()
var beginsAfterNormal = 0
afterNormal.onBegin = { beginsAfterNormal += 1 }
afterNormal.contacts([(0.4, 0.5), (0.46, 0.49)])
check(!afterNormal.scroll(phase: 1), "normal center scroll passes")
afterNormal.contacts([])
check(!afterNormal.scroll(phase: 4), "late ordinary scroll-end passes")
afterNormal.contacts([(0.1, 0.96), (0.16, 0.95)])
afterNormal.contacts([(0.1, 0.92), (0.16, 0.91)])
flush()
check(beginsAfterNormal == 1, "late end event cannot block the next fresh edge gesture")
print("PASS: idle cancellation and late normal scroll-end cannot discard a new gesture")

let tooMany = TrackpadGestureController()
tooMany.prepareSynthetic()
var beginsAfterInvalid = 0
tooMany.onBegin = { beginsAfterInvalid += 1 }
tooMany.contacts([(0.1, 0.96), (0.16, 0.95), (0.2, 0.96)])
tooMany.contacts([(0.1, 0.96), (0.16, 0.95)])
tooMany.contacts([(0.1, 0.92), (0.16, 0.91)])
flush()
check(beginsAfterInvalid == 0, "three fingers dropping to two cannot arm midsequence")
tooMany.contacts([])
tooMany.contacts([(0.1, 0.96), (0.16, 0.95)])
tooMany.contacts([(0.1, 0.92), (0.16, 0.91)])
flush()
check(beginsAfterInvalid == 1, "full lift rearms after invalid initial contacts")
print("PASS: invalid initial contact sequences stay blocked until full lift")
