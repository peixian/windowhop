# WindowHop

A native, local macOS window switcher built around the Contexts keyboard workflow. This is a first working implementation, not yet a complete Contexts clone.

## Build and run

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools). No third-party packages.

```sh
./scripts/build.sh
open dist/WindowHop.app
```

The build is optimized by default. Use `CONFIGURATION=debug ./scripts/build.sh` for debugging. In an environment that forbids SwiftPM's nested sandbox, use `SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh`. This affects the local build process; it does not change macOS security settings.

Allow WindowHop under **System Settings → Privacy & Security → Accessibility**. Open the two-window menu-bar icon, then choose **Enable Keyboard Shortcuts**. Global shortcuts start disabled so an existing switcher is not unexpectedly displaced. WindowHop pauses capture while Contexts is running; quit Contexts yourself when ready to try it.

Choose **Settings…** from the menu-bar icon, or press **Command-comma** while WindowHop is active, to record your own cycling and search shortcuts. Each mode can be disabled independently. Fast Search supports left/right Option, Command, Control, or Fn. Save applies the configuration and remembers it across launches; Cancel discards changes. Global capture pauses while settings are open so recording does not switch windows.

| Action | Input |
| --- | --- |
| Cycle individual windows | Hold Command, press Tab; release Command to switch |
| Cycle backwards | Command-Shift-Tab |
| Search | Control-Space, type, Return |
| Fast Search | Hold Right Option, type, release Right Option |
| Change shortcuts or Fast Search modifier | **Settings…** (Command-comma) |
| Navigate results | Up/Down or Tab/Shift-Tab |
| Switch directly to a result | Command-1 through Command-9 while the switcher is open |
| Use a letter code | Type the displayed code in Search, then Return; in Fast Search, release its modifier |
| Cancel | Escape; ordinary search also closes when you click another app |

These are the defaults. A cycling shortcut must include Command, Control, Option, or Fn; add Shift to cycle backwards and release a required modifier to switch. Settings rejects duplicate bindings and conflicts with reverse cycling. macOS may consume reserved combinations before the local recorder receives them; each recorder has a default preset, including Command-Tab. WindowHop does not change macOS's own shortcut assignments.

Search matches app names and window titles with fuzzy/acronym ranking. The first nine current results show Command-number hints for immediate switching; numbering follows the filtered list. These shortcuts only apply while the switcher is open, and a number with no matching result does nothing.

Search and Fast Search also assign short, unique letter codes to windows. Codes appear after the first nine rows and in numbered rows' hint tooltips. Type a code without Command, then press Return (or release your Fast Search modifier). An exact code makes its window the first result while retaining other fuzzy matches. Assignments stay stable as windows move in recency order and remain frozen while a panel is open; automatic assignments are kept in memory and may change after restarting WindowHop. Multiple windows from the same app receive different codes.

Successfully selected custom queries up to three characters are remembered locally and take priority over automatic codes. Using an existing code keeps its live-window assignment; choosing a different result deliberately teaches that query a new target. A hint such as `w` can therefore reflect a learned selection rather than the app's first letter. **Forget Learned Searches** clears these saved preferences. Plain cycle mode shows only the Command-number hints; letter codes are entered through Search or Fast Search.

## Implementation

- Warm Accessibility index with observers, bounded reads, and reconciliation.
- Per-window recency with a frozen order during each switching session.
- Explicit keyboard modes, paired key suppression, native text editing and a search-readiness input buffer.
- Compact native table with cached icons and reusable rows.
- Public Accessibility focus operations, verified against the actual focused window.
- One isolated, dynamically resolved private helper (`_AXUIElementGetWindow`) supplies stable window IDs, with an AX-reference fallback.

[API research](docs/API-RESEARCH.md) compares AltTab, Hammerspoon, yabai and a minimal Swift switcher. [Product context](PRODUCT.md) and [design rules](DESIGN.md) capture the supplied Contexts reference.

[Browser tab feasibility](docs/BROWSER-TABS.md) evaluates Chrome/Firefox extensions, native messaging, and TabFS. This integration is researched but not implemented.

## Validation

```sh
swift test
./scripts/test-keyboard.sh
./scripts/benchmark-search.sh
```

Use `swift test --disable-sandbox` if the local environment forbids nested SwiftPM sandboxing. The keyboard harness creates synthetic events without installing a global event tap or posting events into other applications.

**Preview Sample Windows** in the menu (Command-Shift-D while the panel is open) previews the UI with labeled sample data. `open dist/WindowHop.app --args --demo` starts that mode directly. Use **Search Windows…** to return to real windows. `--diagnose` prints permission state and window count, starts no keyboard interception, and exits.

See [validation notes](docs/VALIDATION.md) for what was actually tested. Search microbenchmarks do not measure end-to-end keystroke-to-screen or focus latency.

## Current limits

- Spaces and full-screen discovery/focus are best effort. Some off-Space windows are unavailable through the public Accessibility enumeration; broad parity needs further work.
- Secure Keyboard Entry can block the event-tap keyboard path. Native shortcuts remain available; WindowHop reports the limitation.
- Fast Search uses the selected keyboard layout with its hold modifier removed. Native search supports input-method composition; Fast Search does not implement an IME composition UI.
- Sidebar, gestures, Dock badges, close/minimize actions, and complete Contexts search-ranking parity are not implemented.
- AX behavior varies by application. Focus can still fail, especially around dialogs and Space transitions; a failed attempt is reported in the menu and by a sound.
- Learned choices use application identity and window title. They survive restarts with stable titles; a renamed document may need to be learned again.
- An ad-hoc-signed rebuild can invalidate Accessibility access. `SIGN_IDENTITY='your signing identity' ./scripts/build.sh` supports stable local signing if you already have an identity.

No network service, analytics, screenshots, administrator helper, SIP changes, or auto-start installation. App data is in the `dog.malloc.windowhop` preferences domain. Window titles and queries are not logged; learned choices are stored locally.
