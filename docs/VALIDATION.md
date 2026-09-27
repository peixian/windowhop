# Validation

Development host: Apple Silicon, macOS 26.6.2, Apple Swift 6.3.3. Validation performed 2026-09-27.

## Automated

- `swift test --disable-sandbox` passed all **50 tests** on 2026-09-27, including shortcut configuration, modifier normalization, JSON round trips, reverse-cycle conflicts, and automatic/learned search-code behavior.
- `./scripts/test-keyboard.sh` passed. The standalone harness checks custom cycle/search chords, all seven Fast Search modifiers, independently disabled modes, configuration changes, synthetic Fn flags, modifier release, cancellation, paired keyups, Unicode and early-search readiness, including 100 rapid-opening race iterations. It exercises the keyboard controller without installing a live event tap.
- The release `.app` build completed, and `codesign --verify --strict` passed. This verifies the bundle's signature, not Accessibility authorization or live keyboard behavior.

The subsequent selection-highlight adjustment was rebuilt in release mode, signature-verified, and checked visually in the native app. Its inset rounded highlight moved between rows with Down Arrow without changing row density.

## Dependencies and reproduction

- Swift Package Manager declares macOS 13 as the minimum deployment target. The actual development/validation host above is macOS 26.6.2; older systems have not been exercised.
- The project has no third-party Swift package dependencies. Its local `WindowHopCore` module uses Foundation; the executable uses AppKit, ApplicationServices, Carbon, and Darwin. The isolated `_AXUIElementGetWindow` symbol is resolved dynamically, with a retained-reference identity fallback.
- Build/test tools are the installed Apple Swift toolchain, macOS SDK, shell utilities, and `/usr/bin/codesign`. `SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh` produces a release build in `dist/WindowHop.app` and verifies its signature. The environment override avoids nested SwiftPM sandbox failure in this execution environment.
- `scripts/build.sh` uses `SIGN_IDENTITY` when supplied and otherwise an ad-hoc signature. A valid signature does not guarantee persistence of macOS Accessibility grants across rebuilds.
- Real discovery, window focus, and global event capture require Accessibility authorization for the running app's current identity. Demo mode and the keyboard harness do not establish that authorization. WindowHop's text/icon design does not require Screen Recording for thumbnails.

## Native application checks

Two different validation stages must remain distinct:

- **Earlier build, real windows:** launched the `.app`, confirmed Accessibility discovery returned **24 windows**, typed app/title queries in the native search field, and verified filtering through the accessibility tree. Selected Finder's Recents window, observed it become first in per-window recency, and verified Finder's active window was Recents.
- **Latest compact UI, demo data:** visually inspected the actual native application showing six rows, then one filtered result with the panel shrinking accordingly. After the main-menu fix, verified Command-A performed native text selection/editing in the search field.
- **Selection refinement:** verified the system-accent selection has rounded corners and aligns with the query's side margins; moving selection clears the old row and highlights the next one.
- **Shortcut settings, final release:** opened the native settings window with Command-comma, recorded Option-Command-K for search, verified duplicate cycling/search chords disable Save with an inline explanation, restored cycling independently, saved the custom search chord, quit/relaunched, and verified it persisted. Selected Fn for Fast Search and verified Save/reopen preserved it. Restored and saved all defaults after testing; Settings was left open. The bundle includes the generated bunny icon, verified byte-for-byte against the packaged source.

The final rebuilt app still reported missing Accessibility access after the user enabled the grant. It may require an app restart or removal/re-addition in Accessibility settings. The earlier successful 24-window/Finder test does **not** establish working access or focus in that final rebuilt binary. The compact demo proves layout and editing behavior only.

The keyboard harness also covers holding a recorded key across capture resumption: autorepeat cannot begin a new cycle/search/Fast Search gesture, while repeat cycling in an active gesture still works. Native shortcut recording requires no Accessibility access; it does not establish working global capture.

## Dark selection and numbered results

The 2026-09-27 afternoon build replaces the faint dark-mode selection tint with the opaque native selected-content color and paired selected text. Inspected in the actual native app using labeled demo windows: the rounded inset highlight is clearly visible, follows Down Arrow, and the old row returns to normal colors. Light appearance retains its previous tint; explicit Increase Contrast and live appearance transitions were reviewed in code but not exercised through system settings.

The first nine results display Command-number hints in the existing column. Native demo validation covered an out-of-range Command-9 leaving six results open, filtering to Terminal and seeing it renumbered Command-1, and Command-1 ending that filtered session through the commit path. Demo mode does not activate a real target.

The updated standalone keyboard harness passed all nine physical number mappings, result bounds, configured-binding precedence, closed-panel passthrough, repeat/key-up ownership, buffered search opening, stale Fast Search counts, a custom Control-Option cycle, and all seven held Fast Search modifiers. The release bundle was built and signature-verified. Global capture and real activation from a numbered result remain unverified in this rebuilt binary, which reported missing Accessibility permission.

## Letter codes and scrollbar-free overflow

The letter-code build was inspected in the actual native app with 24 labeled sample windows. The first nine rows display Command-number hints; later rows display distinct codes such as `e`, `fe`, `fd`, and `fw`. Entering `fw` in the native search field promoted Finder's Work window from row 24 to the first result, retaining other fuzzy matches. Return ended that preview selection through the commit path. Demo mode does not activate a real target.

Both native scroller controls are disabled; the scroll view and keyboard reveal behavior remain. Native UI scrolling revealed the last two sample rows with no scrollbar or reserved gutter. Up Arrow from the first result wrapped to Finder Work and scrolled it into view with its rounded dark-mode selection visible.

Core regressions cover unique codes for 80 identical windows, synthetic codes absent from titles, learned-query precedence and clearing, Unicode, MRU/title changes, closed windows, frozen background updates, and the numbered-row boundary. Committing an assigned code does not relearn it by title, preventing alias theft between identical windows and reassignment after renaming.

The final release adds an order-independent shortcut cache so recency/visibility changes reuse assignments. Its full 50-test suite and release signature verification passed. The native UI checks above preceded this cache-only change.

## Remaining live matrix

Physical global Command-Tab and held-modifier Fast Search have **not** been tested: Contexts remains present, so its competing shortcuts make takeover behavior ambiguous. Do not count the simulated keyboard harness as a pass for either interaction.

The letter-code rebuild reported missing Accessibility access. Also unverified: final-binary Accessibility discovery/focus after grant recovery, arbitrary keyboard layouts and IME composition, minimized/hidden targets, multiple displays, full-screen/Spaces, sleep/wake, and permission revocation. These require a live session with the appropriate permission and a nonconflicting switcher configuration.

## Performance interpretation

The latest paired standalone run used separately compiled optimized (`-O`) core code, generated app/window titles, **400 measured queries per window count**, and a repeating **20-query cycle** including short, long, missing, and Unicode queries. These are nearest-rank p95 times in milliseconds:

| Windows | Prior baseline search | Prepared search | Warm preparation with reordered windows |
| --- | ---: | ---: | ---: |
| 30 | 3.164416 | 0.030667 | 0.009750 |
| 100 | 10.455833 | 0.102500 | 0.033500 |
| 500 | 66.767958 | 0.477250 | 0.182291 |

Prepared-search timings exclude initial preparation. Warm preparation measures updating an already populated preparation cache while alternating window order. The paired baseline results are the recorded earlier implementation comparison; `./scripts/benchmark-search.sh 400` reproduces the current benchmark protocol and current implementation's operations.

The checked-in harness compiles `WindowHopCore` separately with `swiftc -O -whole-module-optimization`, links a separate `-O` benchmark executable, performs up to 20 warm-up operations, and measures elapsed time with `DispatchTime`. This preserves the core-module boundary rather than treating a fully inlined synthetic loop as application performance.

The final letter-code build was separately measured with the same 400-sample protocol. Nearest-rank p95 milliseconds:

| Windows | Session query with codes | Warm session preparation with reordered windows and codes | Warm begin/end |
| --- | ---: | ---: | ---: |
| 30 | 0.030375 | 0.012375 | 0.002166 |
| 100 | 0.127750 | 0.059375 | 0.015416 |
| 500 | 0.470833 | 0.209667 | 0.032791 |

The shortcut cache avoids normalization/sorting when per-window app/title/bundle identity and preferences are unchanged. First preparation and relevant metadata changes still perform allocation outside the normal warm invocation/query path. Measurements came from the active development machine and include scheduling noise; they are observations, not latency guarantees.

These timings measure in-process computation only. They exclude keyboard capture, main-queue scheduling, AppKit layout/drawing, display refresh, Accessibility IPC, actual operating-system focus changes, and Space animations. The independent focus queue removes WindowHop's own discovery-queue blocking from a committed switch, but **end-to-end switching latency has not been measured**. No sub-millisecond application-latency claim follows from this table.
