# WindowHop design

## Scene and theme

A user invokes the switcher hundreds of times during ordinary desktop work, often without looking directly at it. Follow the Mac's chosen light/dark appearance using native semantic colors, preserving contrast over arbitrary app backgrounds.

## Visual system

Restrained color strategy: native window background and separators, label/secondary-label text, system selection accent. System colors adapt to contrast and appearance preferences; do not substitute web color approximations.

The user's supplied Contexts screenshot is the authority for density and structure. Use SF system typography, a plain 20–22 pt query, 13 pt single-line app/window labels, and quiet 11 pt group/status labels. A roughly 760 pt wide panel fits within the current display, with height adapting to the number of results up to roughly 22 rows. Rows are 26 pt, app icons 19 pt. Align learned query hints, right-aligned app names, icons, and window titles into consistent columns. A single selection background carries state.

Use a restrained native surface, thin border, small corner radius and subtle shadow. The user permits Liquid Glass when useful, but density, readability and latency take priority. No cards inside rows, thumbnails, or animated entrance. Use standard AppKit focus/input and accessible controls. Preserve enough title text to distinguish multiple windows of one application. Cache icons and reuse rows; selection movement must not rebuild the table.

Selection has a 5 pt radius, inset to the same 18 pt content margin as the query. Light appearance uses a subtle system-accent tint. Dark and increased-contrast appearances use the opaque native selection color, paired with native selected text and a visible thin outline. Keep that emphasis while the cycle/Fast Search panel is non-key. Refresh row text and fill together when appearance changes. The highlight must not appear as a square strip ending abruptly against the panel sides. Keep the 26 pt row pitch.

## States

Search mode owns a native editable search field. Cycle and Fast Search show query/status text without taking application focus. Show specific empty/search-no-match and permission states. Demo mode is labeled. Selection remains visible when scrolling.

Keep native scrolling but hide both scrollbar controls and their reserved gutters, regardless of the system's scrollbar preference. Keyboard selection scrolls into view automatically; trackpad and mouse-wheel scrolling stay available. The existing result count indicates overflow without adding another visual control.

The first nine filtered results display compact ⌘1–⌘9 hints in the existing hint column and can be activated immediately. Keep numbering tied to result order, not window identity or scroll position. Search and Fast Search show unique short letter codes for later rows; numbered rows expose their code in the hint tooltip. Codes are plain search input followed by Return or Fast Search modifier release, never Command-letter bindings. Use learned queries first, then automatic mnemonic codes; preserve surviving automatic codes across MRU/title changes and freeze all routing for the open session. Plain cycle mode shows number hints only, since it does not accept typed search. Missing numbered results do nothing; the shortcuts never intercept ordinary application input while the panel is closed.

## Shortcut settings

Use a compact native settings window with three clearly labeled modes, a recorder for each chord, and a popup for the held Fast Search modifier. Keep controls aligned and validation inline. Save commits a draft; Cancel discards it. Recording is local to the settings window, Escape cancels recording, and global capture stays paused until the window closes. A per-binding default preset restores macOS-reserved combinations that may not reach a local recorder. Avoid translating key labels or reading preferences on the event-tap hot path.
