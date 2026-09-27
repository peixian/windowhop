# WindowHop API research

Research checked on 2026-09-27. WindowHop is an independent Swift/AppKit implementation. No third-party implementation source is vendored or copied. References below document API behavior and tradeoffs; they do not establish that WindowHop has passed an integration test.

## References compared

| Project | What its primary sources establish | Relevance and license |
| --- | --- | --- |
| [AltTab](https://github.com/lwouis/alt-tab-macos) | Its [keyboard implementation](https://github.com/lwouis/alt-tab-macos/blob/master/src/events/KeyboardEvents.swift) combines Carbon hotkeys, modifier/event taps, and local events. Its [WindowServer architecture](https://github.com/lwouis/alt-tab-macos/tree/master/src/windowserver) explains private Space inventory and acquisition of AX elements missing from ordinary enumeration. | The broad compatibility reference, not WindowHop's codebase. [GPL-3](https://github.com/lwouis/alt-tab-macos/blob/master/LICENCE.md). |
| [Hammerspoon](https://github.com/Hammerspoon/hammerspoon) | [HSuicore.m](https://github.com/Hammerspoon/hammerspoon/blob/master/Hammerspoon/HSuicore.m) uses public AX enumeration, main-window and raise actions, and the private `_AXUIElementGetWindow` identity bridge. [Hotkey source](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/hotkey/libhotkey.m) uses `RegisterEventHotKey`. [Window documentation](https://www.hammerspoon.org/docs/hs.window.html) explicitly describes missing windows in other Spaces/fullscreen and unwanted pseudo-windows. | Useful small API building blocks and concrete caveats. [MIT](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE). |
| [yabai](https://github.com/asmvik/yabai) | [Window-manager source](https://github.com/asmvik/yabai/blob/master/src/window_manager.c) combines private process-fronting and event records with AX raise for precise focus. [SIP documentation](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) distinguishes Dock-injection features such as Space manipulation and window layers. | Evidence of why exact focus can be harder than application activation. WindowHop does not use these focus protocols or Dock injection. [MIT](https://github.com/asmvik/yabai/blob/master/LICENSE.txt). |
| [voising/alttab](https://github.com/voising/alttab) | Its README describes a compact per-app title-list switcher, an event tap, a nonactivating panel, AX focus, and optional persistent search. It also claims other-Space support. Individual implementation files were unavailable through the research browser. | A narrow shape comparison, not evidence that ordinary AX enumeration always finds every Space. MIT is declared by the repository; no source was reused. |

## WindowHop decisions

### Discovery, tracking, and identity

`NSWorkspace` supplies running regular applications. The index queries each application's `kAXWindowsAttribute`, reads window roles/titles/minimized state through Accessibility, and observes focus, creation, destruction, title, and minimize events. It reconciles periodically because applications differ in which notifications they send. App activation alone never promotes every window: only the actual focused AX window updates per-window recency.

Discovery AX requests run on a private utility-priority serial queue with a 120 ms per-element messaging timeout. The main queue receives immutable `WindowItem` and focus-target snapshots in the same publication. It does not query remote applications while drawing the switcher. Failed reads preserve previous records; explicit destruction and successful complete enumeration remove stale records. Snapshots are guarded by the index lifecycle generation and cleared when the index stops or detects missing Accessibility permission.

The one private discovery helper is `_AXUIElementGetWindow`, resolved dynamically in `WindowIDBridge`. It maps an existing AX reference to a `CGWindowID`. If the symbol is unavailable or fails, the index compares retained references with `CFEqual` and assigns a local identity. This helper does not provide a way to discover windows that AX omitted, and does not manipulate Spaces. It remains an undocumented compatibility dependency.

Apple primary documentation: [AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h), [AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), [AXUIElementSetMessagingTimeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

### Focus

WindowHop requests unminimize, marks the selected window main, unhides/activates its application, then raises the selected AX window. It checks both the frontmost process and that application's focused AX element/window ID. A successful application activation is not counted as a successful window switch. There is one delayed retry, with a refreshed reference; a persistent mismatch is reported.

Committing a selection looks up its cached focus target on the main queue and dispatches directly to a separate user-initiated focus queue. It does not enqueue behind discovery, rescan the desktop, or wait for an unrelated app's AX timeout. The focus queue never reads or mutates discovery's window dictionary, observer registry, or running state. After successful verification it schedules recency reconciliation on the discovery queue without delaying the completion callback.

The exceptional retry resolves only the selected application's actual AX window, using retained-reference equality or its previously cached WindowServer ID. It never revives a disappeared window from an old record. Its fallback per-window ID scan has a 350 ms budget plus any single request already in flight. The 120/250 ms verification delays occur after the raise; they delay the success report, not the initial focus attempt. A previous target's in-flight AX call, a slow selected app, the main event loop, and macOS itself can still add latency. This architecture removes WindowHop's discovery-queue head-of-line blocking; it is not a measured end-to-end latency guarantee.

New sessions, cancellation, and stop invalidate a lock-protected request token immediately on the main queue. Every mutation and delayed retry checks that token. The lock is never held across IPC. An operation racing a check/call boundary or already sent to another process cannot be recalled, so cancellation is best effort for that operation; later actions and stale success callbacks are suppressed.

AX calls may return unsupported actions, invalid elements, or timeouts, and an application can recreate its accessibility objects. Apple documents these limitations in [AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction). The private focus event protocol used by yabai and AltTab is deliberately absent from this version.

### Keyboard capture and overlay

The keyboard/controller implementation must preserve three distinct modes: Command-Tab cycling, ordinary search committed with Return, and Fast Search committed by releasing its hold modifier. It must suppress only captured sequences, process modifier release, permit Escape cancellation, and leave a safe way out after a tap is disabled. The event tap must never wait on AX requests.

Apple documents active filtering and passive observation in [CGEvent tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)). Secure Input is an explicit integration case: AltTab's [input experiment notes](https://github.com/lwouis/alt-tab-macos/blob/master/src/experimentations/README.md) explain that event taps and registered hotkeys have different limitations. A future fallback may use registered hotkeys; it should be validated rather than assumed to fix every sequence.

WindowHop does not disable native symbolic hotkeys. AltTab's [private wrapper](https://github.com/lwouis/alt-tab-macos/blob/master/src/macos/api-wrappers/SkyLight.framework.swift) notes that `CGSSetSymbolicHotKeyEnabled` persists after the process exits, adding recovery requirements. A nonactivating AppKit panel and supported [window collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) allow the overlay to appear without treating it as an ordinary document window. Fullscreen behavior still requires visual testing.

## Current limits and validation boundary

- Accessibility permission is required. The index reports its absence; it does not change privacy settings or request access itself.
- Other Spaces and fullscreen discovery are best effort. Enumerating current AX windows plus observing known windows is not equivalent to AltTab's private all-Space inventory. Cold-start discovery of an unseen Space can miss windows.
- Focus can fail when applications do not implement AX actions consistently, a modal dialog intervenes, or a Space transition changes the active window. Such failure must remain visible.
- Window titles and search strings are local data and are not logged by default. WindowHop does not capture thumbnails, so this design does not require Screen Recording for previews.
- No SIP changes, administrator helper, Dock injection, or low-level private focus events are part of this build.
- Automated core tests and a demo panel validate deterministic behavior and appearance only. Live tests must cover multiple windows of the same app, minimized/hidden windows, duplicate titles, quick Command-Tab, reverse cycling, Escape, both search modes, keyboard layouts, full screen, sleep/wake, and revoked permissions. Test with competing switchers disabled by the user or using nonconflicting shortcuts.
- Stable app identity/signing matters for development permission persistence. A rebuild that macOS treats as a different identity may require the user to grant Accessibility again; a compile alone does not establish working access.
