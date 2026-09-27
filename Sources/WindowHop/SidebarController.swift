import AppKit
import WindowHopCore

/// Optional mouse access to the same cached window index; no window discovery or
/// keyboard interception runs here. Hidden sidebars only poll the pointer.
final class SidebarController {
    var onSelect: ((WindowItem) -> Void)?
    var onClose: ((WindowItem) -> Void)?
    var onMinimize: ((WindowItem) -> Void)?
    var onHide: ((WindowItem) -> Void)?
    var onQuit: ((WindowItem) -> Void)?
    var onExclude: ((WindowItem) -> Void)?
    var onHideSidebar: (() -> Void)?

    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { hideAll(); stopPointerTimer() }
            else { reconcile() }
        }
    }

    private let icons = SwitcherIconCache()
    private var windows: [WindowItem] = []
    private var preferences = WindowHopPreferences.defaults
    private var sidebars: [UInt32: SidebarDisplay] = [:]
    private var displayObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var stopped = false

    init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconcile() }
    }

    deinit {
        pointerTimer?.invalidate()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    func update(windows: [WindowItem], preferences: WindowHopPreferences) {
        self.windows = windows
        self.preferences = preferences
        stopped = false
        // An unused optional sidebar does no icon, native view, or timer work.
        if preferences.sidebarEnabled { icons.prepare(windows: windows) }
        reconcile()
    }

    func stop() {
        stopped = true
        hideAll()
        stopPointerTimer()
        sidebars.removeAll()
    }

    private func hideAll() { for sidebar in sidebars.values { sidebar.hide() } }
    private func stopPointerTimer() { pointerTimer?.invalidate(); pointerTimer = nil }

    private func reconcile() {
        guard !stopped, !suspended, preferences.sidebarEnabled else {
            hideAll()
            stopPointerTimer()
            return
        }
        let screens = NSScreen.screens
        let connected = Set(screens.compactMap(Self.displayID))
        for id in Array(sidebars.keys) where !connected.contains(id) {
            sidebars.removeValue(forKey: id)?.hide()
        }
        let excluded = Set(preferences.ignoredBundleIdentifiers)
        let included = windows.filter { !excluded.contains($0.bundleIdentifier) }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for screen in screens {
            guard let id = Self.displayID(screen) else { continue }
            let sidebar: SidebarDisplay
            if let existing = sidebars[id] { sidebar = existing }
            else {
                sidebar = SidebarDisplay(icons: icons)
                sidebar.onSelect = { [weak self] in self?.onSelect?($0) }
                sidebar.onClose = { [weak self] in self?.onClose?($0) }
                sidebar.onMinimize = { [weak self] in self?.onMinimize?($0) }
                sidebar.onHide = { [weak self] in self?.onHide?($0) }
                sidebar.onQuit = { [weak self] in self?.onQuit?($0) }
                sidebar.onExclude = { [weak self] in self?.onExclude?($0) }
                sidebar.onHideSidebar = { [weak self] in self?.onHideSidebar?() }
                sidebar.onPointerTrackingChanged = { [weak self] in self?.configurePointerTimer() }
                sidebars[id] = sidebar
            }
            let filtered = preferences.sidebarList.apply(to: included, frontmostProcessIdentifier: frontmost,
                displayID: preferences.sidebarCurrentDisplayOnly ? id : nil)
            sidebar.update(windows: filtered, screen: screen, edge: preferences.sidebarEdge,
                           autoHide: preferences.sidebarAutoHide, showsBadges: preferences.showsBadges)
        }
        configurePointerTimer()
        if pointerTimer != nil { updatePointer() }
    }

    private func configurePointerTimer() {
        guard !stopped, !suspended, preferences.sidebarEnabled,
              sidebars.values.contains(where: { $0.requiresPointerTracking }) else {
            stopPointerTimer()
            return
        }
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.updatePointer() }
            timer.tolerance = 0.04
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
    }

    private func updatePointer() {
        let point = NSEvent.mouseLocation
        let time = ProcessInfo.processInfo.systemUptime
        for sidebar in sidebars.values { sidebar.updatePointer(point, time: time) }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SidebarSurface: NSView {
    var onSwipeRight: (() -> Void)?
    override func swipe(with event: NSEvent) {
        if event.deltaX < 0 { onSwipeRight?() }
        else { super.swipe(with: event) }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        layer?.cornerRadius = 7
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SidebarHandle: NSView {
    var onOpen: (() -> Void)?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 1.5
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private enum SidebarEntry: Equatable {
    case group(String)
    case window(WindowItem)
    var window: WindowItem? {
        if case .window(let item) = self { return item }
        return nil
    }
}

private final class SidebarTable: NSTableView {
    var onSwipeRight: (() -> Void)?
    override func swipe(with event: NSEvent) {
        if event.deltaX < 0 { onSwipeRight?() }
        else { super.swipe(with: event) }
    }
    var onContextRow: ((Int) -> NSMenu?)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        onContextRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// Precise trackpad scroll events also reach non-key sidebars. Only a deliberate
/// horizontal finger swipe hides; ordinary vertical scrolling is left untouched.
private final class SidebarScrollView: NSScrollView {
    var onSwipeRight: (() -> Void)?
    private var horizontalTravel: CGFloat = 0
    private var verticalTravel: CGFloat = 0
    private var lastEventTime: TimeInterval = 0
    private var consumedSwipe = false

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) || event.timestamp - lastEventTime > 0.25 {
            horizontalTravel = 0
            verticalTravel = 0
            consumedSwipe = false
        }
        lastEventTime = event.timestamp
        // Remove the scrolling preference so a finger swipe right is consistent.
        horizontalTravel += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? -1 : 1)
        verticalTravel += abs(event.scrollingDeltaY)
        if !consumedSwipe, horizontalTravel < -50, -horizontalTravel > verticalTravel * 2 {
            consumedSwipe = true
            onSwipeRight?()
        }
        if !consumedSwipe { super.scrollWheel(with: event) }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX < 0 { onSwipeRight?() }
        else { super.swipe(with: event) }
    }
}

private final class SidebarRow: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("sidebar-window")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyDown
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.masksToBounds = true
        addSubview(icon)
        addSubview(title)
        addSubview(badge)
        textField = title
        imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 4, width: 16, height: 16)
        title.frame = NSRect(x: 34, y: 4, width: max(0, bounds.width - 45), height: 16)
        let badgeWidth: CGFloat = badge.stringValue.count > 2 ? 18 : (badge.stringValue.count > 1 ? 14 : 10)
        badge.frame = NSRect(x: 30 - badgeWidth, y: 13, width: badgeWidth, height: 10)
    }

    func configure(_ item: WindowItem, icon image: NSImage?, showsBadges: Bool) {
        icon.image = image
        title.stringValue = item.title.isEmpty ? item.appName : item.title
        title.textColor = item.isMinimized || item.isHidden ? .secondaryLabelColor : .labelColor
        let value = showsBadges ? item.badge : nil
        badge.stringValue = value.map { $0.count > 3 ? "•" : $0 } ?? ""
        badge.isHidden = value?.isEmpty ?? true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        let state = item.isMinimized ? ", minimized" : (item.isHidden ? ", hidden" : "")
        toolTip = "\(item.appName): \(title.stringValue)\(state)"
        setAccessibilityLabel("\(item.appName), \(title.stringValue)\(state)")
        needsLayout = true
    }
}

private final class SidebarDisplay: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((WindowItem) -> Void)?
    var onClose: ((WindowItem) -> Void)?
    var onMinimize: ((WindowItem) -> Void)?
    var onHide: ((WindowItem) -> Void)?
    var onQuit: ((WindowItem) -> Void)?
    var onExclude: ((WindowItem) -> Void)?
    var onHideSidebar: (() -> Void)?
    var onPointerTrackingChanged: (() -> Void)?
    var requiresPointerTracking: Bool { autoHide || temporarilyHidden }

    private let panel = SidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let handle = SidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let table = SidebarTable()
    private let scroll = SidebarScrollView()
    private let empty = NSTextField(labelWithString: "No windows on this display")
    private let icons: SwitcherIconCache
    private var iconObserver: UUID?
    private var entries: [SidebarEntry] = []
    private var autoHide = true
    private var showsBadges = true
    private var lastInsideTime: TimeInterval = 0
    private var contextWindow: WindowItem?
    private var menuOpen = false
    private var temporarilyHidden = false
    private var waitsForEdgeExit = false

    init(icons: SwitcherIconCache) {
        self.icons = icons
        super.init()
        for window in [panel, handle] {
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
        panel.title = "WindowHop Sidebar"
        panel.hasShadow = true
        handle.title = "Show WindowHop Sidebar"
        handle.hasShadow = false
        let surface = SidebarSurface()
        surface.onSwipeRight = { [weak self] in self?.hideTemporarily() }
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        let strip = SidebarHandle()
        strip.wantsLayer = true
        strip.setAccessibilityRole(.button)
        strip.setAccessibilityLabel("Show WindowHop Sidebar")
        strip.onOpen = { [weak self] in
            guard let self, !self.waitsForEdgeExit else { return }
            self.reveal()
        }
        handle.contentView = strip
        let heading = NSTextField(labelWithString: "Windows")
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = .secondaryLabelColor
        let options = NSButton(title: "", image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Sidebar options")!, target: self, action: #selector(showOptions))
        options.isBordered = false
        options.setAccessibilityLabel("Sidebar options")
        options.imagePosition = .imageOnly
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.minWidth = 0
        column.width = 276
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectClickedWindow)
        table.onContextRow = { [weak self] in self?.contextMenu(for: $0) }
        table.onSwipeRight = { [weak self] in self?.hideTemporarily() }
        scroll.onSwipeRight = { [weak self] in self?.hideTemporarily() }
        table.setAccessibilityLabel("Sidebar windows")
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        for view in [heading, options, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            heading.topAnchor.constraint(equalTo: surface.topAnchor, constant: 9),
            options.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            options.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            options.widthAnchor.constraint(equalToConstant: 20),
            options.heightAnchor.constraint(equalToConstant: 18),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 31),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -7),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8)
        ])
        iconObserver = icons.observe { [weak self] in self?.refreshVisibleIcons() }
    }

    deinit { if let iconObserver { icons.removeObserver(iconObserver) } }

    func update(windows: [WindowItem], screen: NSScreen, edge: WindowHopPreferences.SidebarEdge, autoHide: Bool, showsBadges: Bool) {
        self.showsBadges = showsBadges
        let wasAutoHide = self.autoHide
        self.autoHide = autoHide
        let updated = Self.grouped(windows)
        if entries != updated { entries = updated; table.reloadData() }
        else { refreshVisibleIcons() }
        empty.isHidden = !windows.isEmpty
        scroll.isHidden = windows.isEmpty
        let bounds = screen.visibleFrame
        let height = min(max(100, CGFloat(entries.count) * 24 + 38), max(100, bounds.height - 32))
        let width = min(276, bounds.width - 24)
        panel.setFrame(NSRect(x: edge == .left ? bounds.minX + 6 : bounds.maxX - width - 6,
                              y: bounds.midY - height / 2, width: width, height: height), display: panel.isVisible)
        handle.setFrame(NSRect(x: edge == .left ? screen.frame.minX : screen.frame.maxX - 3,
                               y: bounds.midY - 36, width: 3, height: 72), display: handle.isVisible)
        if temporarilyHidden {
            panel.orderOut(nil)
            handle.orderFrontRegardless()
        } else if autoHide {
            if !wasAutoHide { panel.orderOut(nil) }
            handle.orderFrontRegardless()
        } else { reveal() }
    }

    func hide() { panel.orderOut(nil); handle.orderOut(nil); menuOpen = false }

    func updatePointer(_ point: NSPoint, time: TimeInterval) {
        guard requiresPointerTracking, !menuOpen else { return }
        let atEdge = handle.frame.insetBy(dx: -2, dy: -4).contains(point)
        if waitsForEdgeExit {
            if !atEdge { waitsForEdgeExit = false }
            return
        }
        if atEdge { reveal(); lastInsideTime = time }
        else if autoHide, panel.isVisible, panel.frame.union(handle.frame).insetBy(dx: -10, dy: -8).contains(point) { lastInsideTime = time }
        else if autoHide, panel.isVisible, time - lastInsideTime > 0.35 { panel.orderOut(nil) }
    }

    private func reveal() {
        let wasTemporary = temporarilyHidden
        temporarilyHidden = false
        waitsForEdgeExit = false
        lastInsideTime = ProcessInfo.processInfo.systemUptime
        panel.orderFrontRegardless()
        if !autoHide { handle.orderOut(nil) }
        if wasTemporary { onPointerTrackingChanged?() }
    }

    @objc private func hideTemporarily() {
        temporarilyHidden = true
        // A swipe/menu dismissal must not immediately reopen under a stationary
        // pointer. Another edge entry restores even an always-visible sidebar.
        waitsForEdgeExit = true
        panel.orderOut(nil)
        handle.orderFrontRegardless()
        onPointerTrackingChanged?()
    }

    private static func grouped(_ windows: [WindowItem]) -> [SidebarEntry] {
        guard windows.contains(where: { $0.spaceTitle != nil }) else { return windows.map(SidebarEntry.window) }
        var order: [String] = []
        var groups: [String: [WindowItem]] = [:]
        for item in windows {
            let title = item.spaceTitle ?? "Other windows"
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        return order.flatMap { [.group($0)] + (groups[$0] ?? []).map(SidebarEntry.window) }
    }

    private func refreshVisibleIcons() {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        for row in range.location..<min(entries.count, NSMaxRange(range)) {
            if let item = entries[row].window, let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRow {
                view.configure(item, icon: icons.icon(for: item.bundleIdentifier), showsBadges: showsBadges)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entries.indices.contains(row) && entries[row].window != nil }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        return entries[row].window == nil
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .window(let item):
            let view = table.makeView(withIdentifier: SidebarRow.reuseID, owner: self) as? SidebarRow ?? SidebarRow(frame: .zero)
            view.configure(item, icon: icons.icon(for: item.bundleIdentifier), showsBadges: showsBadges)
            return view
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("sidebar-group")
            let view = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            view.identifier = identifier
            if view.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.autoresizingMask = [.width]
                label.frame = NSRect(x: 11, y: 5, width: table.bounds.width - 22, height: 14)
                view.addSubview(label)
                view.textField = label
            }
            view.textField?.stringValue = title
            return view
        }
    }

    @objc private func selectClickedWindow() {
        guard entries.indices.contains(table.clickedRow), let item = entries[table.clickedRow].window else { return }
        onSelect?(item)
        if autoHide { panel.orderOut(nil) }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard entries.indices.contains(row), let item = entries[row].window else { return nil }
        contextWindow = item
        let menu = NSMenu()
        menu.delegate = self
        for (title, selector) in [("Switch to Window", #selector(switchContextWindow)), ("Close Window", #selector(closeContextWindow)),
                                  ("Minimize Window", #selector(minimizeContextWindow)), ("Hide Application", #selector(hideContextApp)),
                                  ("Quit Application", #selector(quitContextApp)), ("Exclude Application", #selector(excludeContextApp))] {
            let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            action.target = self
            action.isEnabled = !(item.isApplicationOnly && (selector == #selector(closeContextWindow) || selector == #selector(minimizeContextWindow)))
            menu.addItem(action)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        appendVisibilityActions(to: menu)
        return menu
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.delegate = self
        appendVisibilityActions(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    private func appendVisibilityActions(to menu: NSMenu) {
        let temporary = NSMenuItem(title: "Hide Temporarily", action: #selector(hideTemporarily), keyEquivalent: "")
        temporary.target = self
        menu.addItem(temporary)
        let turnOff = NSMenuItem(title: "Turn Off Sidebar", action: #selector(hideSidebar), keyEquivalent: "")
        turnOff.target = self
        menu.addItem(turnOff)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; lastInsideTime = ProcessInfo.processInfo.systemUptime }
    @objc private func switchContextWindow() { if let item = contextWindow { onSelect?(item) } }
    @objc private func closeContextWindow() { if let item = contextWindow { onClose?(item) } }
    @objc private func minimizeContextWindow() { if let item = contextWindow { onMinimize?(item) } }
    @objc private func hideContextApp() { if let item = contextWindow { onHide?(item) } }
    @objc private func quitContextApp() { if let item = contextWindow { onQuit?(item) } }
    @objc private func excludeContextApp() { if let item = contextWindow { onExclude?(item) } }
    @objc private func hideSidebar() { onHideSidebar?() }
}
