# Browser tab search feasibility

Research date: 2026-09-27. This is a design assessment, not a tested browser integration. No extensions, native hosts, or FUSE software were installed.

**Highly feasible for both Firefox and Chrome. Build a small browser extension and native messaging bridge. Keep Command-Tab window-only; add browser tabs to search, with an optional tabs-only filter.** The difficult work is reliable connection, profile, and focus handling, rather than searching tab titles.

## Options

| Approach | What it provides | Assessment for WindowHop |
| --- | --- | --- |
| WebExtension + native messaging | Full open-tab metadata, browser events, precise tab/window activation | Recommended. Shared browser logic, explicit identities, warm local cache. |
| TabFS | Browser tabs exposed as filesystem entries through an extension, native host, and FUSE | Useful for shell/Emacs workflows, but unnecessary dependencies and a current Chrome compatibility problem. |
| Chrome Apple Events | Enumerate Chrome windows/tabs and set the active tab | Plausible Chrome-only prototype; requires Automation consent and refresh polling rather than a tab event stream. |
| Accessibility UI traversal | Inspect or press visible browser tab controls | A fallback experiment, not a reliable complete index of every background tab. UI shape, hidden controls, and IPC would make it more brittle. |

Chromium's scripting dictionary exposes window tabs, tab IDs, titles, URLs, and writable `active tab index`. Its AppleScript design documents explain the backing tab model. Firefox's corresponding window/tab AppleScript enhancement remains open, so this does not provide a common Chrome/Firefox solution. The polling and Accessibility tradeoffs above are engineering judgments, not measured benchmarks. [Chromium dictionary](https://chromium.googlesource.com/chromium/src.git/+/lkgr/chrome/browser/ui/cocoa/applescript/scripting.sdef), [Chromium scripting design](https://www.chromium.org/developers/design-documents/applescript/), [Firefox issue 939528](https://bugzilla.mozilla.org/show_bug.cgi?id=939528).

## Why not start with TabFS?

The upstream guide advertises Chrome plus partial Firefox/Safari support on macOS/Linux. Setup includes loading an extension, compiling a C filesystem, installing macFUSE on macOS, and registering a native messaging host. Its Firefox instructions use a temporary extension. These are documented installation paths, not evidence that the current releases work together on this Mac. [TabFS guide](https://omar.website/tabfs/).

The retrieved upstream extension is **Manifest V2**, using a persistent background page. Chrome removed Manifest V2 support in Chrome 139; therefore this upstream extension needs a port or replacement for modern stock Chrome. The manifest also requests page access, debugger, management, and capture capabilities far beyond tab title search. [Upstream manifest](https://raw.githubusercontent.com/osnr/TabFS/master/extension/manifest.json), [Chrome support timeline](https://developer.chrome.com/docs/extensions/develop/migrate/mv2-deprecation-timeline).

TabFS does expose the operations we need: `/tabs/by-id/<id>/title.txt`, `url.txt`, `active`, and a `window` symlink; `/windows/<id>/focused` raises the browser window. Reading routes invokes `tabs.query/get`; writing activation invokes `tabs.update` and `windows.update`. The cache is associated with an open file handle, not a pushed, complete tab index. A WindowHop adapter would still need background reconciliation, and should never walk these files while handling a keystroke. That would add filesystem/native/browser round trips to the search path. [TabFS implementation](https://raw.githubusercontent.com/osnr/TabFS/master/extension/background.js).

The retrieved commit-history page last lists December 28, 2024, but that page was cached; treat this as a maintenance signal, not proof of the live repository's latest commit. The concrete concern is the inspected MV2 code. macFUSE is an additional system dependency; no claim is made here about which macFUSE backend or installation privileges TabFS currently needs. [Retrieved history](https://github.com/osnr/TabFS/commits/master/), [macFUSE](https://macfuse.github.io/). TabFS is GPLv3; no source was copied. [License](https://github.com/osnr/TabFS/blob/master/LICENSE).

## Recommended browser bridge

```text
Chrome / Firefox extension
    ⇄ persistent native messaging port
Browser-spawned WindowHop helper
    ⇄ private local IPC
WindowHop tab cache → prepared search snapshot → existing compact list
```

The extension initiates `runtime.connectNative(...)`; the browser launches the helper and communicates through length-prefixed JSON on stdin/stdout. The helper relays to the already-running app over a private Unix socket or equivalent IPC. WindowHop cannot initiate `connectNative` itself. Chrome documents that an open native messaging connection keeps its extension service worker alive. Reconnect with bounded backoff and resynchronize after host/browser/app restarts. [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Chrome worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle).

Initial discovery uses `tabs.query({})`. Subscribe to `onCreated`, `onUpdated`, `onRemoved`, `onAttached`, `onDetached`, `onMoved`, `onReplaced`, and `onActivated`; observe `windows.onFocusChanged` for actual usage order. Creation/activation can precede a final title or URL, so later updates must fill those fields. Firefox exposes the corresponding tab APIs. [Chrome tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs), [Firefox tabs](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs).

Proposed consistency protocol: install listeners before initial discovery, queue changes while taking the snapshot, then publish the snapshot followed by ordered changes. Sequence numbers and a connection generation reject late messages; a gap triggers resync. Remove disconnected targets from selectable results immediately. Scope identities by browser, profile/connection, browser session, and tab ID. An extension-generated profile UUID can be stored locally; a browser profile's human-readable name must not be assumed available. Browser `windowId` is **not** a macOS `CGWindowID`.

On commit, send only the selected identity and request ID. In the extension:

```javascript
const tab = await browser.tabs.update(tabId, { active: true });
await browser.windows.update(tab.windowId, { focused: true });
```

Use the returned window ID to account for tabs moved since indexing. If the destination is minimized, restore it first; preserve fullscreen/maximized state otherwise. Recheck once if a move races activation; report a closed tab rather than opening its URL as a substitute. Serialize/cancel obsolete activation requests as WindowHop already does for AX focus.

`tabs.update({active:true})` alone does not focus the window. Chrome and Firefox document `windows.update({focused:true})` as bringing it forward. These API contracts do **not** prove foreground behavior across macOS Spaces/fullscreen, hidden apps, or multiple browser processes; validate those cases on this Mac. If necessary, add a native app-activation fallback and confirm both the browser's active tab and macOS foreground app. Do not guess an AX window from duplicate titles. [Firefox tab activation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/update), [Chrome window API](https://developer.chrome.com/docs/extensions/reference/api/windows), [Firefox window activation](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/windows/update).

## Permissions and installation

- Request `tabs` for titles/URLs and `nativeMessaging` for the local bridge; `storage` only for settings/profile identity. Neither content scripts nor all-site host access are needed for this scope. `activeTab` alone is insufficient for a continuously indexed list of all tabs. [Chrome tabs permissions](https://developer.chrome.com/docs/extensions/reference/api/tabs).
- Register a per-user host manifest under `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` and `~/Library/Application Support/Mozilla/NativeMessagingHosts/`. Chrome uses `allowed_origins`; Firefox uses `allowed_extensions` and a stable add-on ID. These host registrations do not require a system-wide install. [Chrome registration](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Firefox native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging), [Firefox manifest locations](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests).
- Use shared extension logic with browser-specific manifests: Chrome MV3 service worker, Firefox background scripts/event page. Their background environments are not identical. [Background compatibility](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background).
- Chrome can use a local unpacked extension during development. Firefox's temporary add-on is suitable for testing; permanent release/beta installation requires Mozilla signing, including private unlisted distribution. Developer Edition supports a separate unsigned route, but changing its signing setting should be an explicit user choice. [Firefox distribution](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/).

Proposed privacy behavior: exclude private/incognito tabs by default, keep titles/domain metadata in memory, never log titles/URLs/queries, and never send search text to the extension. Only the committed target identity leaves the app. Restrict IPC to the current user and allowlisted extension; no listening network port or cloud service. Browser extension permission prompts and any optional private-window access remain visible setup steps.

## Performance and product shape

WindowHop already has warm prepared strings, frozen switch-session ordering, and a separate AX focus map. Introduce a typed search target (`window` or `browserTab`) rather than putting browser IDs into the AX map. Cycle sessions continue using native windows only. Search can merge cached tab rows, with browser icon, title, and a subtle domain/profile label in the existing single-line layout. A tabs-only filter avoids flooding the ordinary window list.

The intended input path remains entirely in memory: no filesystem traversal, subprocess launch, browser query, or IPC on each keystroke. Prepare changed strings off the main/event-tap threads; publish immutable snapshots and keep the current order stable while navigating. Use browser application icons initially, avoiding favicon fetches on invocation. A cold/disconnected browser cannot delay the normal window list. Measure tab counts of 100/500/2,000, browser churn, idle memory/CPU, and command-to-visible-focus latency separately.

Firefox also offers `tabs.warmup()` to prepare an inactive tab's rendering without activating it. Consider it only after measuring the basic path; it does not work for discarded tabs, and aggressive warming costs resources. Discarded-tab reload time and macOS Space animations cannot be eliminated by optimizing the search engine. [Firefox warmup](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/warmup).

## Effort estimate and first milestone

Engineering estimates, not measured delivery promises:

| Milestone | Estimated focused work |
| --- | --- |
| One-browser proof: live snapshot, search rows, activation through helper | 1–2 days |
| Both browsers, event updates, restart/reconnect, settings and profile identity | 3–5 days total |
| Comfortable daily use: installer/signing, race tests, private-mode behavior, Spaces/fullscreen and performance checks | About 1–2 weeks total |

The first proof should establish correct activation from another app, a second browser window, and a minimized window before expanding the UI. Then test moving/closing a selected tab, duplicate titles, multiple profiles, browser/helper restarts, discarded tabs, fullscreen and another Space. Keep the feature optional until that matrix passes. None of those live checks has been performed in this research pass.
