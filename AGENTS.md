# WindowHop

Native, local-only macOS window switching inspired by the user's Contexts workflow.

## Routing
- `Sources/WindowHopCore`: deterministic search and switch-session state. No AppKit or IPC.
- `Sources/WindowHop`: AppKit panel, keyboard capture, Accessibility window discovery and focus.
- `Tests/WindowHopCoreTests`: behavior-level search and keyboard session invariants.
- `docs/API-RESEARCH.md`: primary-source research and public/private API decisions.

Read PRODUCT.md and DESIGN.md before UI edits. Preserve the Contexts-style keyboard workflow.
Build with `./scripts/build.sh`; test with `swift test`. Use `--demo` to inspect the panel without Accessibility access; demo is not evidence of real window switching. Actual discovery/focus require Accessibility and a manual integration pass.

The build reads the ignored `.signing-identity` file for persistent certificate signing. Preserve that configuration and the bundle identifier; do not override it with ad-hoc signing when rebuilding the user's app. Never commit or export private signing keys. See `docs/SIGNING.md` for certificate-chain diagnostics and identity verification.

Keep Accessibility IPC off the main/event-tap threads. Do not globally disable system symbolic hotkeys, modify SIP, quit other switchers, or silently change permission settings. If private APIs become necessary, isolate and document them with public fallback. Never log window titles or typed queries by default.
No third-party source is vendored; research citations are not permission to copy code without reviewing its license.
