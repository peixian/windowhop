import Foundation

/// One invocation owns a fixed window snapshot; background MRU changes cannot reorder it.
public struct SwitcherSession {
    public enum Mode: Equatable {
        case cycle
        case search
        case fastSearch
    }

    public private(set) var mode: Mode?
    public private(set) var windows: [WindowItem] = []
    public private(set) var results: [WindowItem] = []
    public private(set) var query = ""
    public private(set) var selectedIndex = 0
    /// Preferred short query per live window, frozen for this invocation.
    public private(set) var searchShortcuts: [String: String] = [:]
    private var learnedPreferences: [String: String] = [:]
    private var preparationCache = SearchEngine.PreparationCache()
    private var shortcutCache = WindowSearchShortcuts()
    private var warmIndex: SearchEngine.PreparedIndex?
    private var warmShortcuts = WindowSearchShortcuts.Snapshot()
    private var warmPreferences: [String: String] = [:]
    private var activeIndex: SearchEngine.PreparedIndex?
    private var activeShortcuts = WindowSearchShortcuts.Snapshot()
    private var activeWindowsByID: [String: WindowItem] = [:]

    public var selected: WindowItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public init() {}

    /// Assigned codes already have a live-window owner. Committing that owner
    /// must not relearn the code as a title-based preference, which cannot
    /// distinguish duplicate titles and becomes stale when a title changes.
    public func isSearchShortcut(_ query: String, forWindowID id: String) -> Bool {
        guard mode != nil else { return false }
        return activeShortcuts.targetByQuery[SearchEngine.normalizedQuery(query)] == id
    }

    /// Warm new index data before keyboard invocation. A live session stays frozen.
    public mutating func prepare(windows: [WindowItem], preferences: [String: String] = [:]) {
        warmIndex = preparationCache.prepare(windows)
        warmShortcuts = shortcutCache.prepare(windows: windows, preferences: preferences)
        warmPreferences = preferences
    }

    public mutating func begin(
        mode: Mode,
        windows: [WindowItem],
        preferences: [String: String] = [:],
        reverse: Bool = false
    ) {
        self.mode = mode
        self.windows = windows
        if warmIndex?.windows != windows || warmPreferences != preferences {
            prepare(windows: windows, preferences: preferences)
        }
        activeIndex = warmIndex
        activeShortcuts = warmShortcuts
        searchShortcuts = activeShortcuts.preferredByID
        activeWindowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = windows
        query = ""
        learnedPreferences = preferences
        if mode == .cycle, !windows.isEmpty {
            selectedIndex = reverse ? windows.count - 1 : min(1, windows.count - 1)
        } else {
            selectedIndex = 0
        }
    }

    public mutating func updateQuery(_ query: String, preferences: [String: String] = [:]) {
        guard mode != nil else { return }
        self.query = query
        learnedPreferences.merge(preferences) { _, new in new }
        if let activeIndex {
            results = SearchEngine().search(query, in: activeIndex, preferences: learnedPreferences)
        }
        // A generated disambiguation code need not occur in the title itself.
        // Exact codes still select their window while retaining other fuzzy hits.
        let normalized = SearchEngine.normalizedQuery(query)
        if let id = activeShortcuts.targetByQuery[normalized], let target = activeWindowsByID[id] {
            results.removeAll { $0.id == id }
            results.insert(target, at: 0)
        }
        selectedIndex = 0
    }

    public mutating func move(_ delta: Int) {
        guard mode != nil, !results.isEmpty else { return }
        let index = selectedIndex + delta % results.count
        selectedIndex = index < 0 ? index + results.count :
            (index >= results.count ? index - results.count : index)
    }

    /// Keep a surviving selection; if it closed, select the next row or the final row.
    public mutating func removeWindow(id: String) {
        let previousID = selected?.id
        windows.removeAll { $0.id == id }
        activeIndex = activeIndex?.removingWindow(id: id)
        activeShortcuts = activeShortcuts.removingWindow(id: id)
        searchShortcuts.removeValue(forKey: id)
        activeWindowsByID.removeValue(forKey: id)
        results.removeAll { $0.id == id }
        if let previousID, let newIndex = results.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        }
    }

    public mutating func end() {
        mode = nil
        windows = []
        results = []
        query = ""
        selectedIndex = 0
        learnedPreferences = [:]
        activeIndex = nil
        activeShortcuts = WindowSearchShortcuts.Snapshot()
        searchShortcuts = [:]
        activeWindowsByID = [:]
    }
}
