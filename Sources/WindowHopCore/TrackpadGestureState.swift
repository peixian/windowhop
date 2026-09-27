import Foundation

/// Recognizes a physical two-finger downward drag from either top corner.
/// Coordinates are normalized hardware contacts (origin at the bottom left),
/// never the on-screen pointer. No platform calls or event injection occur here.
public struct TrackpadGestureState {
    public struct Contact: Equatable {
        public let id: Int32
        public let x: Double
        public let y: Double
        public init(id: Int32, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
    }
    public enum Action: Equatable { case begin, move(Int), commit, cancel }

    public private(set) var ownsScroll = false
    public private(set) var isActive = false
    private var origins: [Int32: Contact] = [:]
    private var firstTime: Double?
    private var pair: Set<Int32> = []
    private var originX = 0.0
    private var originY = 0.0
    private var lastStep = 0
    private var blocked = false
    private var lifting = false

    public init() {}

    /// Refuse to acquire an ordinary scroll sequence after any part was already
    /// delivered. This fails closed if contact and scroll callbacks arrive late.
    public mutating func unownedScrollDidPass() {
        if !ownsScroll { blocked = true }
    }

    @discardableResult
    public mutating func cancel() -> [Action] {
        guard !origins.isEmpty || ownsScroll || isActive else { return [] }
        let actions: [Action] = isActive ? [.cancel] : []
        isActive = false
        blocked = true
        // Retain ownership through finger lift, avoiding a late scroll jump in
        // the underlying app after an owned gesture was cancelled.
        return actions
    }

    public mutating func update(contacts: [Contact], timestamp: Double) -> [Action] {
        guard timestamp.isFinite, contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(contacts.map(\.id)).count == contacts.count else { return reject() }
        if contacts.isEmpty {
            let actions: [Action] = isActive ? [.commit] : []
            self = Self()
            return actions
        }
        guard !blocked else { return [] }
        guard contacts.count <= 2 else { return reject() }
        if firstTime == nil { firstTime = timestamp }
        for contact in contacts where origins[contact.id] == nil {
            origins[contact.id] = contact
        }
        guard origins.count <= 2 else { return reject() }

        if pair.isEmpty {
            guard contacts.count == 2 else { return [] }
            guard timestamp - (firstTime ?? timestamp) <= 0.20 else { return reject() }
            let starts = Array(origins.values)
            guard starts.count == 2, starts.allSatisfy({ $0.y >= 0.88 }),
                  starts.allSatisfy({ $0.x <= 0.25 }) || starts.allSatisfy({ $0.x >= 0.75 }) else { return reject() }
            pair = Set(starts.map(\.id))
            originX = starts.map(\.x).reduce(0, +) / 2
            originY = starts.map(\.y).reduce(0, +) / 2
            ownsScroll = true
        }
        guard Set(contacts.map(\.id)).isSubset(of: pair) else { return reject() }
        if contacts.count == 1 { lifting = true; return [] }
        guard !lifting else { return reject() }
        let x = contacts.map(\.x).reduce(0, +) / 2
        let y = contacts.map(\.y).reduce(0, +) / 2
        let downward = originY - y
        guard abs(x - originX) <= 0.12, downward >= -0.025 else { return reject() }
        if !isActive {
            guard downward >= 0.025 else { return [] }
            guard abs(x - originX) <= 0.04 else { return reject() }
            isActive = true
            // Opening selects the next window, then each extra 5% of surface
            // travel advances one row. Upward movement retraces those rows.
            lastStep = 0
            return [.begin]
        }
        let step = max(0, Int(((downward - 0.025) / 0.05).rounded(.down)))
        let delta = step - lastStep
        lastStep = step
        return delta == 0 ? [] : [.move(delta)]
    }
    /// Invalid physical input blocks the entire contact sequence, including an
    /// invalid first frame before any origin was recorded. External idle cancel
    /// remains a no-op so cancelling a keyboard session cannot eat a gesture.
    private mutating func reject() -> [Action] {
        let actions = cancel()
        blocked = true
        return actions
    }

}
