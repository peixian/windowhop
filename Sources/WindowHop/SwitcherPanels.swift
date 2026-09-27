import AppKit
import WindowHopCore

/// One switch session, mirrored on every display, with one native field editor.
/// Individual panels never own search state or perform window discovery.
final class SwitcherPanels {
    var onQuery: ((String) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onQuickSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onSelection: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCloseSelected: (() -> Void)?
    var onMinimizeSelected: (() -> Void)?
    var onHideSelectedApp: (() -> Void)?
    var onQuitSelectedApp: (() -> Void)?
    var onExcludeApplication: ((WindowItem) -> Void)?

    var showsOnAllDisplays = true {
        didSet {
            guard showsOnAllDisplays != oldValue, activeMode != nil else { return }
            reconcileDisplays()
        }
    }
    var showsBadges = true {
        didSet { for panel in panels.values { panel.showsBadges = showsBadges } }
    }
    var reservedCommandKeyCodes: Set<UInt16> = [] {
        didSet { for panel in panels.values { panel.reservedCommandKeyCodes = reservedCommandKeyCodes } }
    }
    var isVisible: Bool { panels.values.contains { $0.isVisible } }

    private struct RenderState {
        let session: SwitcherSession
        let footer: String
        let emptyMessage: String
        let needsPermission: Bool
    }

    private let iconCache = SwitcherIconCache()
    private var panels: [String: SwitcherPanel] = [:]
    private var preparedWindows: [WindowItem] = []
    private var activeMode: SwitcherSession.Mode?
    private var anchorDisplayID: String?
    private var inputDisplayID: String?
    private var isDemo = false
    private var latestRender: RenderState?
    private var displayObserver: NSObjectProtocol?
    private var changingDisplays = false
    private var presentationGeneration: UInt64 = 0

    init() {
        warmPanels()
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.activeMode != nil { self.reconcileDisplays() }
            else { self.warmPanels() }
        }
    }

    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    func prepare(windows: [WindowItem]) {
        preparedWindows = windows
        iconCache.prepare(windows: windows)
        for panel in panels.values { panel.prepare(windows: windows) }
    }

    func show(mode: SwitcherSession.Mode, screen: NSScreen?, demo: Bool) {
        if activeMode != nil { hide() }
        presentationGeneration &+= 1
        activeMode = mode
        isDemo = demo
        latestRender = nil
        let target = screen ?? pointerScreen()
        anchorDisplayID = target.map(Self.displayID)
        inputDisplayID = anchorDisplayID
        reconcileDisplays()
    }

    func render(_ session: SwitcherSession, footer: String, emptyMessage: String, needsPermission: Bool = false) {
        latestRender = RenderState(session: session, footer: footer, emptyMessage: emptyMessage, needsPermission: needsPermission)
        for panel in panels.values where panel.isVisible {
            panel.render(session, footer: footer, emptyMessage: emptyMessage, needsPermission: needsPermission)
        }
    }

    func hide() {
        presentationGeneration &+= 1
        activeMode = nil
        latestRender = nil
        inputDisplayID = nil
        changingDisplays = true
        for panel in panels.values { panel.hide() }
        changingDisplays = false
    }

    private static func displayID(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return NSStringFromRect(screen.frame)
    }

    private func pointerScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Allocate native controls on display/index changes, never on a search key.
    private func warmPanels() {
        let screens = NSScreen.screens
        let connected = Set(screens.map(Self.displayID))
        for id in Array(panels.keys) where !connected.contains(id) {
            panels.removeValue(forKey: id)?.hide()
        }
        for screen in screens { _ = panel(for: Self.displayID(screen)) }
    }

    private func panel(for id: String) -> SwitcherPanel {
        if let existing = panels[id] { return existing }
        let result = SwitcherPanel(iconCache: iconCache)
        result.showsBadges = showsBadges
        result.reservedCommandKeyCodes = reservedCommandKeyCodes
        result.prepare(windows: preparedWindows)
        result.onQuery = { [weak self] in self?.onQuery?($0) }
        result.onMove = { [weak self] in self?.onMove?($0) }
        result.onCommit = { [weak self] in self?.onCommit?() }
        result.onQuickSelect = { [weak self] in self?.onQuickSelect?($0) }
        result.onCancel = { [weak self] in self?.onCancel?() }
        result.onSelection = { [weak self] in self?.onSelection?($0) }
        result.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        result.onCloseSelected = { [weak self] in self?.onCloseSelected?() }
        result.onMinimizeSelected = { [weak self] in self?.onMinimizeSelected?() }
        result.onHideSelectedApp = { [weak self] in self?.onHideSelectedApp?() }
        result.onQuitSelectedApp = { [weak self] in self?.onQuitSelectedApp?() }
        result.onExcludeApplication = { [weak self] in self?.onExcludeApplication?($0) }
        result.onBecomeKey = { [weak self] in self?.inputDisplayID = id }
        result.onResignKey = { [weak self] in self?.checkForDismissal() }
        panels[id] = result
        return result
    }

    private func reconcileDisplays() {
        guard let activeMode else { return }
        changingDisplays = true
        defer { changingDisplays = false }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            for panel in panels.values { panel.hide() }
            return
        }
        let connected = Set(screens.map(Self.displayID))
        if anchorDisplayID.map({ !connected.contains($0) }) ?? true {
            anchorDisplayID = pointerScreen().map(Self.displayID)
        }
        let targets = showsOnAllDisplays ? screens : screens.filter { Self.displayID($0) == anchorDisplayID }
        let targetIDs = Set(targets.map(Self.displayID))
        if inputDisplayID.map({ !targetIDs.contains($0) }) ?? true { inputDisplayID = anchorDisplayID }
        for id in Array(panels.keys) where !targetIDs.contains(id) {
            panels[id]?.hide()
            if !connected.contains(id) { panels.removeValue(forKey: id) }
        }
        for screen in targets {
            let replica = panel(for: Self.displayID(screen))
            if replica.isVisible {
                replica.position(on: screen, rowCount: latestRender?.session.results.count ?? preparedWindows.count,
                                 needsPermission: latestRender?.needsPermission ?? false)
            } else {
                replica.show(mode: activeMode, screen: screen, demo: isDemo, takesKeyboardFocus: false)
            }
            if let state = latestRender {
                replica.render(state.session, footer: state.footer, emptyMessage: state.emptyMessage, needsPermission: state.needsPermission)
            }
        }
        // Ordering replicas first avoids repeatedly moving native key focus.
        if activeMode == .search, !panels.values.contains(where: { $0.isVisible && $0.isKeyWindow }),
           let inputDisplayID, let owner = panels[inputDisplayID] {
            owner.focusSearch()
        }
    }

    private func checkForDismissal() {
        guard !changingDisplays, activeMode == .search else { return }
        let generation = presentationGeneration
        // AppKit resigns the old key panel before making a clicked replica key.
        // Decide after that handoff, and never cancel a newer invocation.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationGeneration == generation,
                  self.activeMode == .search, !self.changingDisplays,
                  !self.panels.values.contains(where: { $0.isVisible && $0.isKeyWindow }) else { return }
            self.onCancel?()
        }
    }
}
