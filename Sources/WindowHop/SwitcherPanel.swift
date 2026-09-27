import AppKit
import WindowHopCore

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ResultsTable: NSTableView {
    // Keyboard navigation belongs to the switcher; typing always stays in search.
    override var acceptsFirstResponder: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        return super.menu(for: event)
    }
}

private final class PanelSurface: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        layer?.cornerRadius = 9
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A compact selection surface aligned with the panel's text insets.
/// Native table selection otherwise draws a square strip to the scroll edges.
private final class SelectionRow: NSTableRowView {
    private var usesStrongSelection: Bool {
        effectiveAppearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]) != .aqua
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 10, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let strong = usesStrongSelection
        let fill = strong ? NSColor.selectedContentBackgroundColor : NSColor.controlAccentColor.withAlphaComponent(0.13)
        let edge = strong ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.30) : NSColor.controlAccentColor.withAlphaComponent(0.20)
        fill.setFill()
        shape.fill()
        edge.setStroke()
        shape.lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        shape.stroke()
    }

    // Cycling and Fast Search intentionally leave the panel non-key. Their
    // current target must stay just as legible as a focused search selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && usesStrongSelection ? .emphasized : .normal
    }

    override var isSelected: Bool { didSet { updateCellStyles() } }
    override var isEmphasized: Bool { didSet { updateCellStyles() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTableCellView)?.backgroundStyle = interiorBackgroundStyle
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCellStyles()
    }

    private func updateCellStyles() {
        needsDisplay = true
        let style = interiorBackgroundStyle
        for case let cell as NSTableCellView in subviews { cell.backgroundStyle = style }
    }
}

private final class WindowRow: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("window-row")
    let hint = NSTextField(labelWithString: "")
    let appName = NSTextField(labelWithString: "")
    let appIcon = NSImageView()
    let windowTitle = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private(set) var bundleIdentifier = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        for label in [hint, appName, windowTitle] {
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        hint.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        appName.alignment = .right
        windowTitle.lineBreakMode = .byTruncatingMiddle
        appIcon.imageScaling = .scaleProportionallyDown
        addSubview(appIcon)
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.masksToBounds = true
        badge.isHidden = true
        addSubview(badge)
        textField = windowTitle
        imageView = appIcon
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override func layout() {
        super.layout()
        let labelY = (bounds.height - 17) / 2
        let appWidth = min(170, max(85, bounds.width * 0.27))
        hint.frame = NSRect(x: 18, y: labelY, width: 26, height: 17)
        appName.frame = NSRect(x: 48, y: labelY, width: appWidth, height: 17)
        appIcon.frame = NSRect(x: appName.frame.maxX + 10, y: (bounds.height - 19) / 2, width: 19, height: 19)
        let badgeWidth: CGFloat = badge.stringValue.count > 2 ? 20 : (badge.stringValue.count > 1 ? 15 : 12)
        badge.frame = NSRect(x: appIcon.frame.maxX + 4 - badgeWidth, y: appIcon.frame.maxY - 10, width: badgeWidth, height: 12)
        let titleX = appIcon.frame.maxX + 9
        windowTitle.frame = NSRect(x: titleX, y: labelY, width: max(0, bounds.width - titleX - 12), height: 17)
    }

    func configure(_ item: WindowItem, hint shortcut: String, quickNumber: Int?, icon: NSImage?, showsBadge: Bool) {
        bundleIdentifier = item.bundleIdentifier
        hint.stringValue = quickNumber.map { "⌘\($0)" } ?? shortcut
        hint.toolTip = quickNumber.map { "Command-\($0) switches to this result" }
        if !shortcut.isEmpty {
            hint.toolTip = [hint.toolTip, "Type \(shortcut) in search, then Return (or release the Fast Search modifier)"].compactMap { $0 }.joined(separator: " · ")
        }
        appName.stringValue = item.appName
        appIcon.image = icon
        let badgeText = showsBadge ? item.badge : nil
        badge.stringValue = badgeText.map { $0.count > 3 ? "•" : $0 } ?? ""
        badge.isHidden = badgeText?.isEmpty ?? true
        badge.setAccessibilityLabel(badgeText.map { "Badge: \($0)" })
        needsLayout = true
        windowTitle.stringValue = item.title.isEmpty ? item.appName : item.title
        var state = item.isMinimized ? ", minimized" : (item.isHidden ? ", hidden" : "")
        if item.isApplicationOnly { state += ", application with no open windows" }
        if let badgeText, !badgeText.isEmpty { state += ", badge \(badgeText)" }
        toolTip = "\(item.appName): \(windowTitle.stringValue)\(state)"
        setAccessibilityLabel("\(item.appName), \(windowTitle.stringValue)\(state)")
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        appName.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        windowTitle.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        hint.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

/// Shared by display replicas, so a display never repeats application/icon I/O.
final class SwitcherIconCache {
    private var icons: [String: NSImage] = [:]
    private var requested = Set<String>()
    private var observers: [UUID: () -> Void] = [:]
    private let queue = DispatchQueue(label: "WindowHop.icons", qos: .userInitiated)
    private let fallback = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)

    func icon(for bundleIdentifier: String) -> NSImage? { icons[bundleIdentifier] ?? fallback }
    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func prepare(windows: [WindowItem]) {
        let needed = Set(windows.map(\.bundleIdentifier)).filter { !$0.isEmpty && !requested.contains($0) }
        requested.formUnion(needed)
        guard !needed.isEmpty else { return }
        queue.async { [weak self] in
            var loaded: [String: NSImage] = [:]
            for identifier in needed {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                    loaded[identifier] = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
            let resolved = loaded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.icons.merge(resolved) { _, new in new }
                for observer in self.observers.values { observer() }
            }
        }
    }
}

/// Native editing retains keyboard layouts, IME composition and VoiceOver support.
final class SwitcherPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
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
    var onResignKey: (() -> Void)?
    var onBecomeKey: (() -> Void)?
    var showsBadges = true {
        didSet { if showsBadges != oldValue { updateVisibleCells() } }
    }
    var reservedCommandKeyCodes: Set<UInt16> = [] {
        didSet {
            if reservedCommandKeyCodes != oldValue {
                updateVisibleCells()
                updateActionMenuShortcuts()
            }
        }
    }

    private let panel: FloatingPanel
    private let search = NSTextField()
    private let heading = NSTextField(labelWithString: "Switch windows")
    private let group = NSTextField(labelWithString: "All")
    private let table = ResultsTable()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private var rows: [WindowItem] = []
    private var updatingSelection = false
    private var mode: SwitcherSession.Mode = .search
    private var localMonitor: Any?
    private var suppressResign = false
    private var displayBounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private var topEdge: CGFloat = 680
    private var preparedWindowCount = 0
    private var lastRowCount = -1
    private var lastPermissionState = false
    private let iconCache: SwitcherIconCache
    private var iconObserver: UUID?
    private var shortcutHints: [String: String] = [:]
    private var renderedMode: SwitcherSession.Mode?
    private static let quickSelectionKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let quickSelectionKeys = Dictionary(uniqueKeysWithValues: quickSelectionKeyCodes.enumerated().map { ($0.element, $0.offset) })
    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    init(iconCache: SwitcherIconCache = SwitcherIconCache()) {
        self.iconCache = iconCache
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        iconObserver = iconCache.observe { [weak self] in self?.updateVisibleCells() }
        panel.title = "WindowHop"
        panel.delegate = self
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let content = PanelSurface()
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        panel.contentView = content

        search.delegate = self
        search.placeholderString = "Search windows"
        search.font = .systemFont(ofSize: 18)
        search.isBezeled = false
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.usesSingleLineMode = true
        search.lineBreakMode = .byClipping
        search.setAccessibilityLabel("Search windows")
        heading.font = search.font
        heading.lineBreakMode = .byTruncatingTail
        group.font = .systemFont(ofSize: 12, weight: .medium)
        group.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        permissionButton.target = self
        permissionButton.action = #selector(openSettings)
        permissionButton.bezelStyle = .rounded
        permissionButton.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        column.width = 744
        column.minWidth = 0
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 26
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.setAccessibilityLabel("Windows")
        let rowMenu = NSMenu()
        for (title, action, key) in [
            ("Close Window", #selector(closeSelected), "w"),
            ("Minimize Window", #selector(minimizeSelected), "m"),
            ("Hide Application", #selector(hideSelectedApp), "h"),
            ("Quit Application", #selector(quitSelectedApp), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            rowMenu.addItem(item)
        }
        rowMenu.addItem(.separator())
        let exclude = NSMenuItem(title: "Exclude Application from WindowHop", action: #selector(excludeSelectedApp), keyEquivalent: "")
        exclude.target = self
        rowMenu.addItem(exclude)
        table.menu = rowMenu
        scroll.documentView = table
        // The compact keyboard-first list needs scrolling, not a permanent
        // scrollbar gutter (including when macOS is set to always show them).
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let separator = NSBox()
        separator.boxType = .separator
        for view in [search, heading, group, scroll, footer, empty, separator, permissionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            search.heightAnchor.constraint(equalToConstant: 26),
            heading.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            heading.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            separator.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            group.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            group.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 236),
            group.heightAnchor.constraint(equalToConstant: 16),
            scroll.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 13),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 35),
            empty.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -35),
            permissionButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            permissionButton.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 12)
        ])
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible, self.panel.isKeyWindow,
                  event.window == nil || event.window === self.panel else { return event }
            // An explicitly recorded binding belongs to the keyboard engine,
            // even when its key would normally select a result or close a window.
            if ShortcutModifiers(rawValue: UInt64(event.modifierFlags.rawValue)) == .command,
               self.reservedCommandKeyCodes.contains(event.keyCode) { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if ShortcutModifiers(rawValue: UInt64(event.modifierFlags.rawValue)) == .command,
               let index = Self.quickSelectionKeys[event.keyCode] {
                if !event.isARepeat, self.rows.indices.contains(index) { self.onQuickSelect?(index) }
                return nil
            }
            if ShortcutModifiers(rawValue: UInt64(event.modifierFlags.rawValue)) == .command {
                let action: (() -> Void)?
                switch event.keyCode {
                case 13: action = self.onCloseSelected
                case 46: action = self.onMinimizeSelected
                case 4: action = self.onHideSelectedApp
                case 12: action = self.onQuitSelectedApp
                default: action = nil
                }
                if let action {
                    if !event.isARepeat { action() }
                    return nil
                }
            }
            if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return nil }
            switch event.keyCode {
            case 53: self.onCancel?(); return nil
            case 36, 76: self.onCommit?(); return nil
            case 125: self.onMove?(1); return nil
            case 126: self.onMove?(-1); return nil
            case 48: self.onMove?(event.modifierFlags.contains(.shift) ? -1 : 1); return nil
            default: return event
            }
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let iconObserver { iconCache.removeObserver(iconObserver) }
    }

    /// Warm app metadata outside the typing/cycling path. Icon results update
    /// visible cells in place without rebuilding or reordering the list.
    func prepare(windows: [WindowItem]) {
        preparedWindowCount = windows.count
        iconCache.prepare(windows: windows)
    }

    func show(mode: SwitcherSession.Mode, screen: NSScreen?, demo: Bool, takesKeyboardFocus: Bool = true) {
        self.mode = mode
        position(on: screen, rowCount: preparedWindowCount, needsPermission: false)
        search.isHidden = mode != .search
        heading.isHidden = mode == .search
        search.stringValue = ""
        footer.stringValue = demo ? "Demo windows" : ""
        if mode == .search, takesKeyboardFocus { focusSearch() }
        else { panel.orderFrontRegardless() }
    }

    /// Display changes reposition an existing session without clearing its input.
    func position(on screen: NSScreen?, rowCount: Int, needsPermission: Bool) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        displayBounds = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let openingHeight = desiredHeight(rowCount: rowCount, needsPermission: needsPermission)
        topEdge = min(displayBounds.maxY - 20, displayBounds.midY + openingHeight / 2 + 25)
        lastRowCount = -1
        fitPanel(rowCount: rowCount, needsPermission: needsPermission)
    }

    func focusSearch() {
        guard mode == .search else { return }
        panel.makeKeyAndOrderFront(nil)
        prepareSearchEditor()
    }

    private func prepareSearchEditor() {
        panel.makeFirstResponder(search)
        if let editor = panel.fieldEditor(false, for: search) as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }
    }

    func render(_ session: SwitcherSession, footer text: String, emptyMessage: String, needsPermission: Bool = false) {
        let changed = rows != session.results
        let hintsChanged = shortcutHints != session.searchShortcuts || renderedMode != session.mode
        shortcutHints = session.searchShortcuts
        renderedMode = session.mode
        if changed { rows = session.results }
        // The key panel owns the field editor (including IME composition).
        // Other displays mirror committed query state without an input caret.
        if !panel.isKeyWindow, search.stringValue != session.query { search.stringValue = session.query }
        heading.stringValue = session.query.isEmpty ? "Switch windows" : session.query
        group.stringValue = session.query.isEmpty ? "All" : "Matches"
        footer.stringValue = text
        empty.stringValue = emptyMessage
        empty.isHidden = !rows.isEmpty
        permissionButton.isHidden = !needsPermission
        scroll.isHidden = rows.isEmpty
        updatingSelection = true
        if changed { table.reloadData() }
        else if hintsChanged { updateVisibleCells() }
        if rows.indices.contains(session.selectedIndex) {
            if table.selectedRow != session.selectedIndex {
                table.selectRowIndexes(IndexSet(integer: session.selectedIndex), byExtendingSelection: false)
            }
            table.scrollRowToVisible(session.selectedIndex)
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
        updatingSelection = false
        fitPanel(rowCount: rows.count, needsPermission: needsPermission)
    }

    func hide() {
        suppressResign = true
        panel.orderOut(nil)
        suppressResign = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressResign, panel.isVisible, mode == .search else { return }
        if let onResignKey { onResignKey() } else { onCancel?() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?()
        if mode == .search { prepareSearchEditor() }
    }

    private func desiredHeight(rowCount: Int, needsPermission: Bool) -> CGFloat {
        let listHeight: CGFloat = rowCount == 0 ? (needsPermission ? 122 : 76) : CGFloat(min(22, rowCount)) * 26
        return min(110 + listHeight, max(150, displayBounds.height - 40))
    }

    private func fitPanel(rowCount: Int, needsPermission: Bool) {
        guard rowCount != lastRowCount || needsPermission != lastPermissionState else { return }
        lastRowCount = rowCount
        lastPermissionState = needsPermission
        let size = NSSize(width: min(760, displayBounds.width - 32), height: desiredHeight(rowCount: rowCount, needsPermission: needsPermission))
        let origin = NSPoint(x: displayBounds.midX - size.width / 2, y: max(displayBounds.minY + 20, topEdge - size.height))
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    private func updateActionMenuShortcuts() {
        for item in table.menu?.items ?? [] {
            let shortcut: (UInt16, String)
            switch item.action {
            case #selector(closeSelected): shortcut = (13, "w")
            case #selector(minimizeSelected): shortcut = (46, "m")
            case #selector(hideSelectedApp): shortcut = (4, "h")
            case #selector(quitSelectedApp): shortcut = (12, "q")
            default: continue
            }
            item.keyEquivalent = reservedCommandKeyCodes.contains(shortcut.0) ? "" : shortcut.1
        }
    }

    private func updateVisibleCells() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<min(rows.count, NSMaxRange(visible)) {
            if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WindowRow { configure(view, row: row) }
        }
    }

    private func configure(_ view: WindowRow, row: Int) {
        let item = rows[row]
        let hint = mode == .cycle ? "" : (shortcutHints[item.id] ?? "")
        let quickNumber = row < Self.quickSelectionKeyCodes.count && !reservedCommandKeyCodes.contains(Self.quickSelectionKeyCodes[row]) ? row + 1 : nil
        view.configure(item, hint: hint, quickNumber: quickNumber, icon: iconCache.icon(for: item.bundleIdentifier), showsBadge: showsBadges)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SelectionRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: WindowRow.reuseID, owner: self) as? WindowRow ?? WindowRow(frame: .zero)
        configure(view, row: row)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updatingSelection, table.selectedRow >= 0 { onSelection?(table.selectedRow) }
    }

    func controlTextDidChange(_ obj: Notification) { onQuery?(search.stringValue) }
    @objc private func doubleClick() { if table.clickedRow >= 0 { onCommit?() } }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func closeSelected() { onCloseSelected?() }
    @objc private func minimizeSelected() { onMinimizeSelected?() }
    @objc private func hideSelectedApp() { onHideSelectedApp?() }
    @objc private func quitSelectedApp() { onQuitSelectedApp?() }
    @objc private func excludeSelectedApp() {
        guard rows.indices.contains(table.selectedRow) else { return }
        onExcludeApplication?(rows[table.selectedRow])
    }
}
