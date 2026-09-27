<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="WindowHop rabbit icon">
</p>

<h1 align="center">WindowHop</h1>

<p align="center">Fast, compact window switching for macOS. Inspired by <a href="https://contexts.co/">Contexts</a>.</p>

Switch individual windows, search by app or title, and jump to results with number shortcuts or short letter codes. Built with Swift and AppKit, with a compact native interface and no third-party packages.

## Get started

Requires **macOS 13+** and Xcode or Command Line Tools.

```sh
git clone https://github.com/peixian/windowhop.git
cd windowhop
./scripts/build.sh
open dist/WindowHop.app
```

1. Allow WindowHop in **System Settings → Privacy & Security → Accessibility**.
2. Quit Contexts if it is running; WindowHop pauses global shortcuts while Contexts is open.
3. Open WindowHop's menu-bar menu and choose **Enable Keyboard Shortcuts**.

To try the interface without permissions, choose **Preview Sample Windows** from the menu.

## Keyboard controls

| Action | Default shortcut |
| --- | --- |
| Cycle windows | Hold **⌘**, press **Tab**, release **⌘** to switch |
| Cycle backwards | **⌘⇧Tab** |
| Search | **Control-Space**, type, then **Return** |
| Fast Search | Hold **Right Option**, type, then release |
| Move through results | **↑ / ↓** or **Tab / ⇧Tab** |
| Switch to one of the first nine results | **⌘1–9** while the panel is open |
| Cancel | **Esc** |

Choose **Settings…** from the menu, or press **⌘,** while WindowHop is active, to record your own shortcuts. Each mode can be disabled independently. Fast Search supports left/right Option, Command, Control, or Fn. Settings persist across launches.

### Letter codes

In Search and Fast Search, windows beyond the first nine show codes such as `e`, `fd`, or `fw`. Type the code **without Command**, then press **Return** or release your Fast Search modifier. Its window becomes the first result.

Codes stay attached to windows as the list reorders, and multiple windows from the same app get distinct codes. Automatic codes may change after restarting WindowHop. Custom queries of up to three characters are learned when you select a result; **Forget Learned Searches** clears them.

## Current status

WindowHop is an early implementation of the Contexts keyboard workflow. Spaces and full-screen switching are best effort. Browser-tab search is [researched](docs/BROWSER-TABS.md) but not implemented; sidebar, gestures, and window-management actions are also outside the current feature set.

**Rebuilding can reset Accessibility access** with the default ad-hoc signature. If shortcuts or window discovery stop working after a build, re-enable WindowHop in Accessibility settings. Secure Keyboard Entry can also prevent global shortcut capture.

Everything runs locally. No network service, analytics, or Screen Recording permission is needed. Learned searches are stored in macOS preferences; window titles and queries are not logged.

## Development

```sh
swift test
./scripts/test-keyboard.sh
./scripts/benchmark-search.sh
```

Builds use release optimization by default. Set `CONFIGURATION=debug` for a debug build, or `SIGN_IDENTITY` to use an existing signing identity. If your environment blocks SwiftPM's nested sandbox, use `SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh` and `swift test --disable-sandbox`.

- [Validation and performance](docs/VALIDATION.md) — tested behavior, benchmarks, and remaining checks. Core timings do not measure end-to-end switching latency.
- [API research](docs/API-RESEARCH.md) — Accessibility APIs, alternatives, and the isolated private window-ID helper.
- [Product](PRODUCT.md) · [Design](DESIGN.md) · [Icon](docs/ICON.md)
