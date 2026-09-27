import Foundation

/// Deterministic fuzzy search. Input order supplies the MRU tie-breaker.
public struct SearchEngine {
    public init() {}

    /// Immutable search data for a frozen window snapshot. Character folding and
    /// boundary detection happen during preparation, never during query scoring.
    public struct PreparedIndex {
        public let windows: [WindowItem]
        fileprivate let entries: [IndexedWindow]
        fileprivate let symbols: [Character: UInt32]
        public var count: Int { entries.count }

        func removingWindow(id: String) -> PreparedIndex {
            PreparedIndex(windows: windows.filter { $0.id != id },
                          entries: entries.filter { $0.item.id != id }, symbols: symbols)
        }
    }

    /// Reuses unchanged text across invocations and MRU reorderings. This is a
    /// value owned by a session, with no process-wide mutable cache or AX access.
    public struct PreparationCache {
        private var windowsByID: [String: IndexedWindow] = [:]
        private var applications: [String: PreparedText] = [:]
        private var symbolTable = SymbolTable()
        public init() {}

        public mutating func prepare(_ windows: [WindowItem]) -> PreparedIndex {
            var entries: [IndexedWindow] = []
            entries.reserveCapacity(windows.count)
            var nextWindows: [String: IndexedWindow] = [:]
            nextWindows.reserveCapacity(windows.count)
            for window in windows {
                let entry: IndexedWindow
                if let cached = windowsByID[window.id],
                   cached.item.appName == window.appName, cached.item.title == window.title,
                   cached.item.bundleIdentifier == window.bundleIdentifier {
                    entry = IndexedWindow(item: window, app: cached.app, title: cached.title,
                                          combined: cached.combined, preferenceKey: cached.preferenceKey)
                } else {
                    let app: PreparedText
                    if let cachedApp = applications[window.appName] { app = cachedApp }
                    else {
                        app = PreparedText(window.appName, symbols: &symbolTable)
                        applications[window.appName] = app
                    }
                    let title = PreparedText(window.title, symbols: &symbolTable)
                    let identity = SearchEngine.normalizedQuery(window.bundleIdentifier.isEmpty ? window.appName : window.bundleIdentifier)
                    entry = IndexedWindow(item: window, app: app, title: title,
                                          combined: IndexedText(app: app.indexed, title: title.indexed),
                                          preferenceKey: "\(identity.count):\(identity)\(title.normalized.count):\(title.normalized)")
                }
                entries.append(entry)
                nextWindows[window.id] = entry
            }
            windowsByID = nextWindows
            let liveApplications = Set(windows.map(\.appName))
            applications = applications.filter { liveApplications.contains($0.key) }
            return PreparedIndex(windows: windows, entries: entries, symbols: symbolTable.values)
        }
    }

    public func prepare(_ windows: [WindowItem]) -> PreparedIndex {
        var cache = PreparationCache()
        return cache.prepare(windows)
    }

    public static func normalizedQuery(_ query: String) -> String {
        fold(query).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Unlike a live window ID, this survives an application restart.
    /// Length prefixes avoid ambiguous keys when a title contains a separator.
    public static func preferenceKey(for window: WindowItem) -> String {
        let app = normalizedQuery(window.bundleIdentifier.isEmpty ? window.appName : window.bundleIdentifier)
        let title = normalizedQuery(window.title)
        return "\(app.count):\(app)\(title.count):\(title)"
    }

    public func search(_ query: String, in windows: [WindowItem], preferences: [String: String] = [:]) -> [WindowItem] {
        guard !Self.normalizedQuery(query).isEmpty else { return windows }
        return search(query, in: prepare(windows), preferences: preferences)
    }

    public func search(_ query: String, in index: PreparedIndex, preferences: [String: String] = [:]) -> [WindowItem] {
        let normalized = Self.normalizedQuery(query)
        guard !normalized.isEmpty else { return index.windows }
        var tokens: [[UInt32]] = []
        for token in normalized.split(separator: " ") {
            var characters: [UInt32] = []
            characters.reserveCapacity(token.count)
            for character in token {
                if let ascii = character.asciiValue { characters.append(UInt32(ascii)) }
                else if let symbol = index.symbols[character] { characters.append(symbol) }
                else { return [] } // A grapheme absent from the entire snapshot cannot match.
            }
            tokens.append(characters)
        }
        let preferredKey = preferences[normalized]
        var ranked: [(score: Int, offset: Int)] = []
        ranked.reserveCapacity(index.count)
        // Reuse two scratch buffers across fields, tokens and windows.
        var previous: [Int] = []
        var current: [Int] = []
        for (offset, entry) in index.entries.enumerated() {
            var score = 0
            var matched = true
            for token in tokens {
                let app = Self.match(token, in: entry.app.indexed, previous: &previous, current: &current)
                let title = Self.match(token, in: entry.title.indexed, previous: &previous, current: &current)
                let combined = Self.match(token, in: entry.combined, previous: &previous, current: &current)
                let best = max(app ?? Int.min, title ?? Int.min, combined ?? Int.min)
                guard best != Int.min else { matched = false; break }
                score += best
            }
            guard matched else { continue }
            if normalized == entry.app.normalized { score += 300 }
            if normalized == entry.title.normalized { score += 300 }
            if preferredKey == entry.preferenceKey { score += 10_000 }
            ranked.append((score, offset))
        }
        ranked.sort { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
        return ranked.map { index.windows[$0.offset] }
    }

    private static func fold(_ value: String) -> String {
        // Most app names, queries and titles are ASCII. Avoid Foundation/ICU for
        // those, while retaining its original Unicode folding for everything else.
        if value.utf8.allSatisfy({ $0 < 128 }) {
            return String(decoding: value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
        }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                             locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    fileprivate struct SymbolTable {
        var values: [Character: UInt32] = [:]
        mutating func intern(_ character: Character) -> UInt32 {
            if let ascii = character.asciiValue { return UInt32(ascii) }
            if let existing = values[character] { return existing }
            let symbol = UInt32(values.count) + 128
            values[character] = symbol
            return symbol
        }
    }

    fileprivate struct IndexedWindow {
        let item: WindowItem
        let app: PreparedText
        let title: PreparedText
        let combined: IndexedText
        let preferenceKey: String
    }

    fileprivate struct PreparedText {
        let normalized: String
        let indexed: IndexedText
        init(_ text: String, symbols: inout SymbolTable) {
            normalized = SearchEngine.normalizedQuery(text)
            indexed = IndexedText(text, symbols: &symbols)
        }
    }

    fileprivate struct IndexedText {
        let characters: [UInt32]
        let boundaries: [Bool]
        let acronym: [UInt32]

        init(app: IndexedText, title: IndexedText) {
            characters = app.characters + [32] + title.characters
            boundaries = app.boundaries + [false] + title.boundaries
            acronym = app.acronym + title.acronym
        }

        init(_ text: String, symbols: inout SymbolTable) {
            var characters: [UInt32] = []
            var boundaries: [Bool] = []
            var acronym: [UInt32] = []
            // CRLF is one Swift Character, so leave it to the grapheme path.
            if text.utf8.allSatisfy({ $0 < 128 }), !text.contains("\r\n") {
                let bytes = Array(text.utf8)
                characters.reserveCapacity(bytes.count)
                boundaries.reserveCapacity(bytes.count)
                for (offset, byte) in bytes.enumerated() {
                    let previous = offset > 0 ? bytes[offset - 1] : 0
                    let next = offset + 1 < bytes.count ? bytes[offset + 1] : 0
                    let uppercase = (65...90).contains(byte)
                    let word = uppercase || (97...122).contains(byte) || (48...57).contains(byte)
                    let previousWord = (65...90).contains(previous) || (97...122).contains(previous) || (48...57).contains(previous)
                    let camel = uppercase && ((97...122).contains(previous) || ((65...90).contains(previous) && (97...122).contains(next)))
                    let boundary = word && (offset == 0 || !previousWord || camel)
                    let folded = UInt32(uppercase ? byte + 32 : byte)
                    characters.append(folded)
                    boundaries.append(boundary)
                    if boundary { acronym.append(folded) }
                }
            } else {
                let original = Array(text)
                characters.reserveCapacity(original.count)
                boundaries.reserveCapacity(original.count)
                for (offset, character) in original.enumerated() {
                    let previous = offset > 0 ? original[offset - 1] : nil
                    let next = offset + 1 < original.count ? original[offset + 1] : nil
                    let startsWord = offset == 0 || previous.map { !Self.isWord($0) } == true
                    let camel = character.isUppercase && (previous?.isLowercase == true ||
                        (previous?.isUppercase == true && next?.isLowercase == true))
                    let boundary = Self.isWord(character) && (startsWord || camel)
                    var first = true
                    for folded in SearchEngine.fold(String(character)) {
                        let symbol = symbols.intern(folded)
                        characters.append(symbol)
                        boundaries.append(first && boundary)
                        if first && boundary { acronym.append(symbol) }
                        first = false
                    }
                }
            }
            self.characters = characters
            self.boundaries = boundaries
            self.acronym = acronym
        }

        private static func isWord(_ character: Character) -> Bool {
            character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
    }

    /// Scores the best ordered subsequence in O(query length × text length).
    /// Numeric symbols preserve whole-grapheme equality, including compound emoji.
    private static func match(_ query: [UInt32], in text: IndexedText,
                              previous: inout [Int], current: inout [Int]) -> Int? {
        let count = text.characters.count
        guard !query.isEmpty, query.count <= count else { return nil }
        // Reject absent/out-of-order letters before allocating or scoring.
        var cursor = 0
        for character in text.characters where character == query[cursor] {
            cursor += 1
            if cursor == query.count { break }
        }
        guard cursor == query.count else { return nil }
        let unavailable = Int.min / 4
        if previous.count < count {
            previous = Array(repeating: unavailable, count: count)
            current = Array(repeating: unavailable, count: count)
        }
        var maximum = unavailable
        for (queryIndex, sought) in query.enumerated() {
            var bestEarlier = unavailable
            maximum = unavailable
            for position in 0..<count {
                current[position] = unavailable
                if queryIndex > 0, position >= 2, previous[position - 2] != unavailable {
                    bestEarlier = max(bestEarlier, previous[position - 2] + position - 2)
                }
                guard text.characters[position] == sought else { continue }
                let letterScore = 12 + (text.boundaries[position] ? 24 : 0)
                if queryIndex == 0 {
                    current[position] = letterScore + (position == 0 ? 30 : 0) - min(position, 30)
                } else {
                    let adjacent = position > 0 && previous[position - 1] != unavailable ? previous[position - 1] + 28 : unavailable
                    let separated = bestEarlier != unavailable ? bestEarlier - position + 1 : unavailable
                    let best = max(adjacent, separated)
                    if best != unavailable { current[position] = best + letterScore }
                }
                maximum = max(maximum, current[position])
            }
            swap(&previous, &current)
        }
        guard maximum != unavailable else { return nil }
        var score = maximum
        if text.characters == query { score += 450 }
        else if text.characters.starts(with: query) { score += 200 }
        else if let start = text.characters.indices.first(where: { index in
            index + query.count <= count && text.characters[index..<(index + query.count)].elementsEqual(query)
        }) {
            score += 90 + (text.boundaries[start] ? 25 : 0)
        }
        if text.acronym == query { score += 170 }
        else if text.acronym.starts(with: query) { score += 100 }
        return score
    }
}
