# Product

## Register

product

## Users

Peixian, a keyboard-heavy macOS user who likes Contexts and wants a maintainable personal implementation. Ordinary desktop windows dominate usage; full-screen and Spaces support are desirable. Both shortcut-and-Return search and hold-modifier-and-release search are essential.

## Product Purpose

Switch to a specific window with predictable, minimal keystrokes. Command-Tab cycles individual windows in last-used order. Search matches application names and window titles and learns short query choices.

## Brand Personality

Quiet, immediate, precise. Contexts is the functional and visual reference. The interface should be familiar enough to preserve muscle memory.

## Anti-references

No launcher dashboard, marketing copy, thumbnail grid, decorative animation, chat interface, or cloud dependency.

## Design Principles

1. Correct focus and imperceptible input latency are the primary success criteria.
2. Keep ordering stable during a switching session.
3. Distinguish real windows, empty results, missing permissions and demo data.
4. Keep the active window unchanged until selection is committed.
5. Make failed activation and unavailable keyboard capture visible and recoverable.
6. Match the supplied Contexts screenshot: compact single-line rows, aligned application and title columns, small icons, and visible learned-query hints. Information density is a feature.
7. Measure search latency. Prepare indexes and icons before invocation, reuse native cells, and avoid animations or repeated layout work during selection.
8. Let the user record cycling and search shortcuts, choose a sided Fast Search modifier, and disable each mode independently. Preserve settings across launches and reject conflicting bindings before saving.
9. Keep numbered selection for the first nine results and show unique, stable search codes for later rows. Type a code and commit through Return or Fast Search modifier release. Learned choices override automatic assignments without changing an open session's codes.

## Accessibility & Inclusion

Native controls and system fonts, semantic colors, full keyboard navigation, visible selection, and system appearance. Respect reduced motion; no transition animation is required.
