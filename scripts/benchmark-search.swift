import Foundation
#if SEARCH_CORE_MODULE
import WindowHopCore
#endif

/// Synthetic local search benchmark; it neither enumerates nor prints real window titles.
/// Run with scripts/benchmark-search.sh [samples-per-size].
@main
enum SearchBenchmark {
    static let queries = ["s", "sa", "saf", "safari", "bu", "bud", "budget", "ed", "edi", "editor",
                          "vsc", "proposal pages", "resume", "東京", "context", "win", "wh", "swift", "no-match-zz", ""]

    static func fixture(count: Int) -> [WindowItem] {
        let apps = ["Safari", "Visual Studio Code", "Terminal", "Pages", "Éditeur", "Finder", "Notes", "Emacs", "Mail", "Firefox"]
        let titles = ["WindowHop — SearchEngine.swift — local workspace",
                      "Budget proposal and quarterly planning — project notes",
                      "Contexts window switching and Accessibility API documentation",
                      "Résumé 東京 🐕 — field notes and reference material",
                      "README.md — architecture, implementation, and validation",
                      "Research papers — memory management and operating systems"]
        return (0..<count).map { index in
            let app = apps[index % apps.count]
            return WindowItem(id: "window-\(index)", appName: app,
                              title: "\(titles[(index / apps.count + index) % titles.count]) \(index)",
                              bundleIdentifier: "benchmark.app\(index % apps.count)")
        }
    }

    static func measure(_ label: String, windows: Int, samples: Int, operation: (Int) -> Int) {
        var checksum = 0
        for index in 0..<min(samples, 20) { checksum &+= operation(index) }
        var durations: [Double] = []
        durations.reserveCapacity(samples)
        for index in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = operation(index)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            checksum &+= value
            durations.append(Double(elapsed) / 1_000_000)
        }
        durations.sort()
        func percentile(_ fraction: Double) -> Double {
            durations[max(0, Int(ceil(fraction * Double(durations.count))) - 1)]
        }
        let mean = durations.reduce(0, +) / Double(durations.count)
        print(String(format: "%@ windows=%d samples=%d mean=%.6fms p50=%.6fms p95=%.6fms p99=%.6fms max=%.6fms checksum=%d",
                     label, windows, samples, mean, percentile(0.50), percentile(0.95), percentile(0.99), durations.last!, checksum))
    }

    #if PREPARED_SEARCH
    // Keep the invocation boundary opaque so whole-module optimization cannot
    // eliminate a begin/end pair whose only observed result would be array.count.
    @inline(never)
    static func invoke(_ session: inout SwitcherSession, windows: [WindowItem], reverse: Bool) -> Int {
        session.begin(mode: .cycle, windows: windows, reverse: reverse)
        let checksum = session.results.count + (session.selected?.id.utf8.count ?? 0)
        session.end()
        return checksum
    }
    #endif

    static func main() {
        let samples = max(20, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 400)
        print("Release (-O), separately compiled core module, synthetic fixtures; per-operation elapsed latency, nearest-rank percentiles.")
        for count in [30, 100, 500] {
            let windows = fixture(count: count)
            let engine = SearchEngine()
            let preferences = ["bu": SearchEngine.preferenceKey(for: windows[1])]
            measure("uncached", windows: count, samples: samples) { index in
                engine.search(queries[index % queries.count], in: windows, preferences: preferences).count
            }
            #if PREPARED_SEARCH
            measure("prepare", windows: count, samples: min(samples, 100)) { _ in
                engine.prepare(windows).count
            }
            let prepared = engine.prepare(windows)
            var cache = SearchEngine.PreparationCache()
            _ = cache.prepare(windows)
            let reversed = Array(windows.reversed())
            measure("warm-prepare-reorder", windows: count, samples: samples) { index in
                cache.prepare(index.isMultiple(of: 2) ? windows : reversed).count
            }
            measure("prepared", windows: count, samples: samples) { index in
                engine.search(queries[index % queries.count], in: prepared, preferences: preferences).count
            }
            var session = SwitcherSession()
            session.prepare(windows: windows)
            measure("warm-session-prepare-reorder", windows: count, samples: samples) { index in
                session.prepare(windows: index.isMultiple(of: 2) ? windows : reversed)
                return count
            }
            session.prepare(windows: windows)
            measure("warm-begin-and-end", windows: count, samples: samples) { index in
                invoke(&session, windows: windows, reverse: index.isMultiple(of: 2))
            }
            session.begin(mode: .search, windows: windows, preferences: preferences)
            measure("session-query", windows: count, samples: samples) { index in
                session.updateQuery(queries[index % queries.count])
                return session.results.count
            }
            #endif
        }
    }
}
