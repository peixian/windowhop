// Concatenated after the panel sources by scripts/test-displays.sh. These hooks
// exist only in the test executable; no diagnostics ship with WindowHop.
// Real AppKit windows are created on the connected NSScreens. No external apps
// are inspected, and no synthetic input is posted.

private struct DisplaySnapshot {
    let frame: NSRect
    let isVisible: Bool
    let isKeyWindow: Bool
    let query: String
    let selectedRow: Int
    let rowCount: Int
    let inputOwnsEditor: Bool
}

extension SwitcherPanel {
    fileprivate var displayTestSnapshot: DisplaySnapshot {
        DisplaySnapshot(frame: panel.frame, isVisible: panel.isVisible, isKeyWindow: panel.isKeyWindow,
                        query: search.stringValue, selectedRow: table.selectedRow, rowCount: rows.count,
                        inputOwnsEditor: panel.isKeyWindow && search.currentEditor() === panel.firstResponder)
    }

    fileprivate func editOwnQueryForTest(_ query: String) {
        // Exercise the native field/delegate path without synthesizing an event.
        search.stringValue = query
        (search.currentEditor() as? NSTextView)?.string = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    }
}

extension SwitcherPanels {
    fileprivate var displayTestSnapshots: [String: DisplaySnapshot] {
        panels.mapValues(\.displayTestSnapshot).filter { $0.value.isVisible }
    }

    fileprivate func editOwnQueryForTest(_ query: String) {
        panels.values.first(where: { $0.isKeyWindow })?.editOwnQueryForTest(query)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let displayScreens = NSScreen.screens
let displayPanels = SwitcherPanels()
var displaySession = SwitcherSession()
var displayAssertions = 0
var unexpectedDismissals = 0

func displayFlush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
func displayCheck(_ value: @autoclosure () -> Bool, _ message: String) {
    displayAssertions += 1
    guard value() else {
        displayPanels.hide()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
func screenID(_ screen: NSScreen) -> String {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
        ?? NSStringFromRect(screen.frame)
}
func renderDisplaySession() {
    displayPanels.render(displaySession, footer: "Display component test", emptyMessage: "No demo matches")
    displayFlush()
}
func checkDisplayState(on screens: [NSScreen], query: String, selectedRow: Int, resultCount: Int) {
    let snapshots = displayPanels.displayTestSnapshots
    displayCheck(snapshots.count == screens.count, "one visible panel per expected display")
    for screen in screens {
        guard let snapshot = snapshots[screenID(screen)] else {
            displayCheck(false, "panel exists for connected display")
            continue
        }
        displayCheck(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(snapshot.frame), "panel fits its display's usable frame")
        displayCheck(abs(snapshot.frame.midX - screen.visibleFrame.midX) < 1, "panel is centered on its own display")
        displayCheck(snapshot.query == query, "native search field mirrors the query")
        displayCheck(snapshot.selectedRow == selectedRow, "native table mirrors the selection")
        displayCheck(snapshot.rowCount == resultCount, "native table mirrors filtered results")
    }
    displayCheck(snapshots.values.filter(\.isKeyWindow).count == 1, "exactly one native key window")
    displayCheck(snapshots.values.filter(\.inputOwnsEditor).count == 1, "exactly one active native search editor")
    displayCheck(unexpectedDismissals == 0, "display reconciliation does not cancel the session")
}

displayCheck(!displayScreens.isEmpty, "WindowServer supplies at least one display")
let targetScreen = displayScreens.last!
let samples = [
    WindowItem(id: "display-test-a", appName: "WindowHop Demo", title: "Alpha note", bundleIdentifier: ""),
    WindowItem(id: "display-test-b", appName: "WindowHop Demo", title: "Alpha draft", bundleIdentifier: ""),
    WindowItem(id: "display-test-c", appName: "WindowHop Demo", title: "Beta note", bundleIdentifier: "")
]
displayPanels.onCancel = { unexpectedDismissals += 1 }
displayPanels.onQuery = { query in
    displaySession.updateQuery(query)
    displayPanels.render(displaySession, footer: "Display component test", emptyMessage: "No demo matches")
}
displayPanels.prepare(windows: samples)
displaySession.begin(mode: .search, windows: samples)
displayPanels.show(mode: .search, screen: targetScreen, demo: true)
renderDisplaySession()
checkDisplayState(on: displayScreens, query: "", selectedRow: 0, resultCount: 3)
displayCheck(displayPanels.displayTestSnapshots[screenID(targetScreen)]?.isKeyWindow == true, "requested display initially owns input")

displayPanels.editOwnQueryForTest("Alpha")
displayFlush()
displayCheck(displaySession.query == "Alpha", "native field delegate updates shared session")
displayCheck(displaySession.results.count == 2, "shared search filters both matching demo windows")
displaySession.move(1)
renderDisplaySession()
checkDisplayState(on: displayScreens, query: "Alpha", selectedRow: 1, resultCount: 2)

displayPanels.showsOnAllDisplays = false
displayFlush()
checkDisplayState(on: [targetScreen], query: "Alpha", selectedRow: 1, resultCount: 2)
displayPanels.showsOnAllDisplays = true
displayFlush()
checkDisplayState(on: displayScreens, query: "Alpha", selectedRow: 1, resultCount: 2)

// Exercise the real screen-change callback without changing the user's displays.
NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
displayFlush()
checkDisplayState(on: displayScreens, query: "Alpha", selectedRow: 1, resultCount: 2)

displayPanels.hide()
displayFlush()
displayCheck(displayPanels.displayTestSnapshots.isEmpty, "hide dismisses every replica")
displayCheck(!displayPanels.isVisible, "facade visibility clears after hide")
print("Display harness: \(displayAssertions) checks passed on \(displayScreens.count) connected display(s).")
if displayScreens.count < 2 {
    print("Only one display is connected; cross-display coverage requires running with two or more.")
}
print("Verified native construction/state only; physical clicks, display hotplug, and cross-Space rendering still require manual checks.")
