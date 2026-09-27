import Foundation

/// Automatic search codes belong to live window identities, not their current
/// MRU position. Only the cache changes during preparation; open sessions keep
/// their own immutable snapshot.
struct WindowSearchShortcuts {
    struct Snapshot {
        var preferredByID: [String: String] = [:]
        var targetByQuery: [String: String] = [:]

        func removingWindow(id: String) -> Snapshot {
            Snapshot(preferredByID: preferredByID.filter { $0.key != id },
                     targetByQuery: targetByQuery.filter { $0.value != id })
        }
    }

    // Keep generated codes separate from learned queries. Forgetting learned
    // searches must not leave those queries behind as automatic assignments.
    private var automaticByID: [String: String] = [:]
    private var cachedWindowsByID: [String: WindowItem] = [:]
    private var cachedPreferences: [String: String] = [:]
    private var cachedSnapshot: Snapshot?

    mutating func prepare(windows: [WindowItem], preferences: [String: String]) -> Snapshot {
        // MRU ordering and visibility flags do not affect shortcut ownership.
        // Reuse assignments without allocating a comparison dictionary, folding
        // text, or sorting when only those properties changed.
        if let cachedSnapshot, cachedPreferences == preferences,
           cachedWindowsByID.count == windows.count,
           windows.allSatisfy({ item in
               guard let cached = cachedWindowsByID[item.id] else { return false }
               return cached.appName == item.appName && cached.title == item.title &&
                   cached.bundleIdentifier == item.bundleIdentifier
           }) {
            return cachedSnapshot
        }
        let ordered = windows.map { item in
            (item: item, app: SearchEngine.normalizedQuery(item.appName),
             title: SearchEngine.normalizedQuery(item.title))
        }.sorted {
            if $0.app != $1.app { return $0.app < $1.app }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.item.id < $1.item.id
        }.map(\.item)

        var learned: [String: String] = [:]
        // Persisted queries are normalized already. Sorting also gives older or
        // manually imported, differently-cased duplicates a deterministic owner.
        for query in preferences.keys.sorted() {
            let normalized = SearchEngine.normalizedQuery(query)
            guard !normalized.isEmpty, normalized.count <= 3 else { continue }
            if learned[normalized] == nil || query == normalized {
                learned[normalized] = preferences[query]
            }
        }

        var firstWindowByPreference: [String: String] = [:]
        for item in ordered {
            let key = SearchEngine.preferenceKey(for: item)
            if firstWindowByPreference[key] == nil { firstWindowByPreference[key] = item.id }
        }

        var snapshot = Snapshot()
        for query in learned.keys.sorted(by: Self.preferredQuery) {
            guard let key = learned[query], let id = firstWindowByPreference[key] else { continue }
            snapshot.targetByQuery[query] = id
            if snapshot.preferredByID[id] == nil { snapshot.preferredByID[id] = query }
        }

        // Reserve learned queries even when their window is temporarily absent.
        // A familiar learned code must not become an unrelated automatic code.
        var used = Set(learned.keys)
        var nextAutomatic: [String: String] = [:]
        for item in ordered {
            guard let code = automaticByID[item.id], used.insert(code).inserted else { continue }
            nextAutomatic[item.id] = code
            snapshot.targetByQuery[code] = item.id
            if snapshot.preferredByID[item.id] == nil { snapshot.preferredByID[item.id] = code }
        }

        var fallbackOffsets: [String: Int] = [:]
        for item in ordered where snapshot.preferredByID[item.id] == nil {
            let candidates = Self.candidates(for: item)
            let code: String
            if let available = candidates.first(where: { !used.contains($0) }) {
                code = available
            } else {
                let initial = candidates.first ?? "w"
                var offset = fallbackOffsets[initial, default: 0]
                var available: String
                repeat {
                    available = initial + Self.alphabeticSuffix(offset)
                    offset += 1
                } while used.contains(available)
                fallbackOffsets[initial] = offset
                code = available
            }
            used.insert(code)
            nextAutomatic[item.id] = code
            snapshot.targetByQuery[code] = item.id
            snapshot.preferredByID[item.id] = code
        }
        automaticByID = nextAutomatic
        cachedWindowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedPreferences = preferences
        cachedSnapshot = snapshot
        return snapshot
    }

    private static func preferredQuery(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    private static func candidates(for item: WindowItem) -> [String] {
        let appWords = words(in: item.appName)
        let titleWords = Array(words(in: item.title).prefix(8))
        let appLetters = appWords.joined().drop(while: { !$0.isLetter })
        let initial = appLetters.first.map(String.init) ?? "w"
        var candidates: [String] = []
        var seen = Set<String>()
        func append(_ code: String) {
            guard !code.isEmpty, code.count <= 3, code.first?.isLetter == true,
                  seen.insert(code).inserted else { return }
            candidates.append(code)
        }

        append(initial)
        append(String(appWords.compactMap(\.first).prefix(3)))
        for word in titleWords { append(initial + String(word.prefix(1))) }
        append(initial + String(titleWords.compactMap(\.first).prefix(2)))
        for word in titleWords { append(initial + String(word.prefix(2))) }
        append(String(appLetters.prefix(2)))
        append(String(appLetters.prefix(3)))
        return candidates
    }

    private static func words(in text: String) -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var word = ""
        func finishWord() {
            guard !word.isEmpty else { return }
            words.append(SearchEngine.normalizedQuery(word))
            word = ""
        }
        for (offset, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else { finishWord(); continue }
            let previous = offset > 0 ? characters[offset - 1] : nil
            let next = offset + 1 < characters.count ? characters[offset + 1] : nil
            let camelBoundary = character.isUppercase &&
                (previous?.isLowercase == true || (previous?.isUppercase == true && next?.isLowercase == true))
            if camelBoundary { finishWord() }
            word.append(character)
        }
        finishWord()
        return words
    }

    /// a...z, aa...az, ba...; no single-letter or two-letter capacity limit.
    private static func alphabeticSuffix(_ offset: Int) -> String {
        var remaining = offset
        var bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(remaining % 26) + 97)
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }
}
