# Validation

Development host: Apple Silicon, macOS 26.6.2, Apple Swift 6.3.3. Checked September 27, 2026. SwiftPM targets macOS 13; older systems have not been exercised.

## Automated checks

- `swift test --disable-sandbox`: **75 tests passed**. Covers fuzzy and learned search, stable letter codes, frozen sessions, shortcut migration/conflicts, independent list policies, preferences, and physical-contact gesture recognition.
- `./scripts/test-keyboard.sh`: passed. Exercises the real controller with synthetic events, without installing a live event tap. Includes all seven Fast Search modifiers, explicit shortcut precedence over numbered selection/navigation/actions, current-app and alternate switchers, cycle-to-search release, Unicode/readiness buffering, paired keyups, repeats, cancellation, and 100 rapid-opening race iterations.
- `./scripts/test-trackpad.sh`: passed. Exercises raw contact parsing, corner origins, scroll/momentum ownership, Escape pairing, silent cancellation, multiple-trackpad ownership, and invalid initial contacts. It does not establish hardware compatibility or actual callback ordering.
- `./scripts/test-displays.sh`: **71 checks passed on two real connected displays**. Constructs the actual AppKit panel components, verifies per-display geometry, one key window/active field editor, query and selection synchronization, the one-display opt-out, restoring both panels, screen-change reconciliation, and dismissal. Requires an interactive WindowServer session; the execution sandbox exposed no screens, so this check ran outside it. It posts no input to other applications.
- Release build and `codesign --verify --strict`: passed. A valid bundle signature does not establish Accessibility authorization or live keyboard behavior.

No third-party Swift packages are used. AppKit, ApplicationServices, Carbon, and Darwin provide the native layer; the core uses Foundation. The isolated window-ID, Space metadata, and physical-touch integrations resolve private symbols dynamically. Their fallbacks and compatibility limits are documented in [CONTEXTS-PARITY.md](CONTEXTS-PARITY.md).

## Native application checks

The actual release application was inspected through native accessibility and screenshots, using labeled sample windows where permission was unavailable:

- Compact 24-row panel, solid rounded dark selection, automatic letter codes, and scrolling without a visible scrollbar or gutter.
- Native query editing, `fw` promoting Finder Work, numbered-result selection, and keyboard wrapping/reveal were validated during the earlier letter-code build.
- All four Settings tabs fit without clipped controls. The Window Lists tab selects one independently stored profile at a time.
- Turned off **Show the switcher on every display**, saved, reopened Settings, and verified the saved opt-out. Restored it to **on** and verified persistence.
- Changed the main list's minimized-window policy to **Don't show**, saved, and observed the minimized sample disappear while the remaining 23 rows retained their codes. Restored normal order afterward.
- Enabled the Sidebar with auto-hide off and visually inspected its compact 24-row sample list. Restored Sidebar off and auto-hide on afterward. Its pointer-edge reveal, menu dismissal, and physical swipe behavior remain unverified.
- In demo mode, Command-W removed only the selected sample window; Command-Q removed the selected sample application's entries while WindowHop stayed open. These checks never closed or quit a real application.
- The user's existing custom search shortcut was preserved. Gesture capture remained disabled. The generated bunny icon remains packaged in the app.

Two real, nonmirrored displays were connected: Studio Display (logical 2560×1440) and Dell U2725QE (logical 1920×1080). The UI automation surface exposed one WindowHop window at a time and no usable app-window inventory. The separate native component harness verified simultaneous construction and synchronized state on both screens. Physical click-to-transfer editing, true plug/unplug, and cross-Space visual presentation remain unverified.

### Permission and live-action boundary

The intermediate rebuilt app reported missing Accessibility access, so the settings and action checks above used demo data. **The final release launch recognized Accessibility access:** it displayed 23 real window/application entries, including hidden and windowless apps and nonempty Dock badges. Typing `finder downloads` narrowed the list to the real Finder Downloads window; after Return, Finder's active window was Downloads. This establishes discovery, native search, and one normal focus path in the final binary. Ad-hoc signatures can still require restarting or re-adding future rebuilds in Accessibility settings.

Physical global Command-Tab and held-modifier Fast Search remain unverified: Contexts was left running, and WindowHop pauses capture while it is present. Synthetic harnesses do not count as live event-tap validation.

Still requiring a permitted, nonconflicting live session: real close/minimize/hide/quit and unsaved-document dialogs; hidden/minimized activation; physical gesture devices; display hotplug and click focus transfer; full-screen/Space transitions and badge updates; arbitrary keyboard layouts/IME composition; sleep/wake and permission revocation. No claim of complete historical Contexts parity follows from the implemented feature checklist.

## Performance

The latest standalone run compiled the core separately with `swiftc -O -whole-module-optimization` and linked a separate optimized benchmark. It used synthetic fixtures, 400 measured operations per window count, up to 20 warm-up operations, a repeating 20-query cycle including missing/Unicode queries, and nearest-rank p95 elapsed times measured with `DispatchTime`.

| Windows | Query including codes | Warm preparation, reordered windows | Warm begin/end |
| --- | ---: | ---: | ---: |
| 30 | 0.030625 ms | 0.013209 ms | 0.003167 ms |
| 100 | 0.087042 ms | 0.039750 ms | 0.009750 ms |
| 500 | 0.433958 ms | 0.203000 ms | 0.048333 ms |

Queries reuse normalized search data and stable shortcut assignments. Metadata discovery and icon preparation happen outside the input path; one session feeds every display. First preparation, relevant metadata changes, and changing a list profile still require work that these warm timings exclude.

These are in-process measurements, not end-to-end switching latency. They exclude event delivery, main-queue scheduling, AppKit layout/drawing, display refresh, AX IPC, actual focus changes, and Space animations. Multiple displays increase drawing work; a larger Sidebar can increase background updates. No sub-millisecond application-latency guarantee follows from this table.

## Reproduction

```sh
swift test --disable-sandbox
./scripts/test-keyboard.sh
./scripts/test-trackpad.sh
./scripts/test-displays.sh
./scripts/benchmark-search.sh 400
SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh
```

The sandbox flags avoid nested SwiftPM sandbox failure in this execution environment. The build script defaults to release optimization and ad-hoc signing; `SIGN_IDENTITY` selects an existing signing identity. Preview Sample Windows requires no Accessibility access and never focuses or modifies real target windows. Diagnostic runs keep all keyboard/gesture capture and the Sidebar disabled.
