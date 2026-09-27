import AppKit
import Carbon
import WindowHopCore

/// Shortcut names follow the active keyboard layout, not an assumed US layout.
func shortcutDisplayName(_ shortcut: KeyboardShortcut) -> String {
    shortcutModifierSymbols(shortcut.modifiers, keyCode: shortcut.keyCode) + shortcutKeyName(shortcut.keyCode)
}

extension FastSearchModifier {
    var displayName: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .leftOption: return "Left Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .leftCommand: return "Left Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .leftControl: return "Left Control ⌃"
        case .fn: return "Fn / Globe 🌐"
        }
    }
}

private func shortcutModifierSymbols(_ modifiers: ShortcutModifiers, keyCode: UInt16? = nil) -> String {
    var result = ""
    // Navigation and function keys carry the function flag without a physical Fn press.
    if modifiers.contains(.fn), keyCode.map({ !KeyboardShortcut.hasImplicitFunctionFlag(keyCode: $0) }) ?? true { result += "fn " }
    if modifiers.contains(.control) { result += "⌃" }
    if modifiers.contains(.option) { result += "⌥" }
    if modifiers.contains(.shift) { result += "⇧" }
    if modifiers.contains(.command) { result += "⌘" }
    return result
}

private func shortcutKeyName(_ key: UInt16) -> String {
    let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]
    if let name = special[key] { return name }
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return "Key \(key)"
    }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return "Key \(key)" }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var deadKeyState: UInt32 = 0
    var count = 0
    var characters = [UniChar](repeating: 0, count: 8)
    let result = UCKeyTranslate(
        layout, key, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &count, &characters
    )
    guard result == noErr, count > 0 else { return "Key \(key)" }
    let name = String(utf16CodeUnits: characters, count: count)
    guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        return "Key \(key)"
    }
    return name.uppercased()
}

/// A local recorder must receive Command combinations before the application's menu.
private final class ShortcutRecordingWindow: NSWindow {
    var captureKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow, captureKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class ShortcutSettingsWindow: NSObject, NSWindowDelegate {
    var onSave: ((ShortcutConfiguration, WindowHopPreferences) -> Void)?
    var onClose: (() -> Void)?
    var gestureStatus = "" { didSet { gestureFeedback.stringValue = gestureStatus } }
    var isVisible: Bool { settingsWindow?.isVisible ?? false }

    private enum RecordingTarget { case cycle, appCycle, alternateCycle, search }
    private var settingsWindow: ShortcutRecordingWindow?
    private var draft = ShortcutConfiguration.defaults
    private var preferences = WindowHopPreferences.defaults
    private var recording: RecordingTarget?
    private var eventMonitor: Any?
    private var suppressedKeys = Set<UInt16>()
    private var keyboardLayoutObserver: NSObjectProtocol?
    private var closing = false
    private let cycleEnabled = NSButton(checkboxWithTitle: "Window switching", target: nil, action: nil)
    private let appCycleEnabled = NSButton(checkboxWithTitle: "Current app windows", target: nil, action: nil)
    private let alternateEnabled = NSButton(checkboxWithTitle: "Alternate switcher", target: nil, action: nil)
    private let appCycleRecorder = NSButton(title: "", target: nil, action: nil)
    private let alternateRecorder = NSButton(title: "", target: nil, action: nil)
    private let appCycleReset = NSButton(title: "", target: nil, action: nil)
    private let alternateReset = NSButton(title: "", target: nil, action: nil)
    private let allDisplays = NSButton(checkboxWithTitle: "Show the switcher on every display", target: nil, action: nil)
    private let sidebarEnabled = NSButton(checkboxWithTitle: "Enable Sidebar", target: nil, action: nil)
    private let sidebarAutoHide = NSButton(checkboxWithTitle: "Hide until the pointer reaches the screen edge", target: nil, action: nil)
    private let sidebarCurrentDisplay = NSButton(checkboxWithTitle: "Only show windows on that display", target: nil, action: nil)
    private let gestureEnabled = NSButton(checkboxWithTitle: "Enable trackpad edge gesture (experimental)", target: nil, action: nil)
    private let gestureFeedback = NSTextField(wrappingLabelWithString: "")
    private let badges = NSButton(checkboxWithTitle: "Show app badges when available", target: nil, action: nil)
    private let sidebarEdge = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ignoredApps = NSPopUpButton(frame: .zero, pullsDown: false)
    private let restoreApp = NSButton(title: "Show App", target: nil, action: nil)
    private let editedList = NSPopUpButton(frame: .zero, pullsDown: false)
    private var listEditors: [WindowListSettingsView] = []
    private let searchEnabled = NSButton(checkboxWithTitle: "Search windows", target: nil, action: nil)
    private let fastEnabled = NSButton(checkboxWithTitle: "Fast Search", target: nil, action: nil)
    private let cycleRecorder = NSButton(title: "", target: nil, action: nil)
    private let searchRecorder = NSButton(title: "", target: nil, action: nil)
    private let cycleReset = NSButton(title: "", target: nil, action: nil)
    private let searchReset = NSButton(title: "", target: nil, action: nil)
    private let fastModifier = NSPopUpButton(frame: .zero, pullsDown: false)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let modifiers: [FastSearchModifier] = [
        .rightOption, .leftOption, .rightCommand, .leftCommand, .rightControl, .leftControl, .fn
    ]

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let keyboardLayoutObserver { DistributedNotificationCenter.default().removeObserver(keyboardLayoutObserver) }
    }

    func show(configuration: ShortcutConfiguration, preferences: WindowHopPreferences) {
        if isVisible {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        draft = configuration
        self.preferences = preferences
        closing = false
        if settingsWindow == nil { buildWindow() }
        finishRecording()
        renderDraft()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let window = ShortcutRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "WindowHop Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.captureKeyEquivalent = { [weak self] event in self?.capture(event) ?? false }
        settingsWindow = window
        guard let content = window.contentView else { return }

        let tabs = NSTabView()
        let keyboardPage = NSView()
        let generalPage = makeGeneralPage()
        let listsPage = makeListsPage()
        let sidebarPage = makeSidebarPage()
        for (name, page) in [("General", generalPage), ("Shortcuts", keyboardPage), ("Window Lists", listsPage), ("Sidebar", sidebarPage)] {
            let item = NSTabViewItem(identifier: name)
            item.label = name
            item.view = page
            tabs.addTabViewItem(item)
        }
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0

        configureRecorder(cycleRecorder, action: #selector(recordCycle), label: "Window switching shortcut")
        configureRecorder(appCycleRecorder, action: #selector(recordAppCycle), label: "Current app windows shortcut")
        configureRecorder(alternateRecorder, action: #selector(recordAlternate), label: "Alternate switcher shortcut")
        configureRecorder(searchRecorder, action: #selector(recordSearch), label: "Search windows shortcut")
        cycleEnabled.target = self
        cycleEnabled.action = #selector(updateEnabled)
        searchEnabled.target = self
        searchEnabled.action = #selector(updateEnabled)
        appCycleEnabled.target = self
        appCycleEnabled.action = #selector(updateEnabled)
        alternateEnabled.target = self
        alternateEnabled.action = #selector(updateEnabled)
        fastEnabled.target = self
        fastEnabled.action = #selector(updateEnabled)
        fastModifier.addItems(withTitles: modifiers.map(\.displayName))
        fastModifier.target = self
        fastModifier.action = #selector(updateModifier)
        fastModifier.setAccessibilityLabel("Fast Search modifier")

        let cycleControls = recorderControls(cycleRecorder, reset: cycleReset,
                                              action: #selector(restoreCycle),
                                              label: "Restore Command-Tab")
        let appCycleControls = recorderControls(appCycleRecorder, reset: appCycleReset,
                                                  action: #selector(restoreAppCycle), label: "Restore Command-Backquote")
        let alternateControls = recorderControls(alternateRecorder, reset: alternateReset,
                                                   action: #selector(restoreAlternate), label: "Restore Option-Tab")
        let searchControls = recorderControls(searchRecorder, reset: searchReset,
                                               action: #selector(restoreSearch),
                                               label: "Restore Control-Space")
        let cycleRow = makeRow(cycleEnabled, control: cycleControls,
                               detail: "Add Shift to go backward. Release to switch.")
        let appCycleRow = makeRow(appCycleEnabled, control: appCycleControls,
                                   detail: "Cycle windows belonging to the frontmost app.")
        let alternateRow = makeRow(alternateEnabled, control: alternateControls,
                                    detail: "Use the alternate filters in Window Lists.")
        let searchRow = makeRow(searchEnabled, control: searchControls,
                                detail: "Type a window name, then press Return.")
        let fastRow = makeRow(fastEnabled, control: fastModifier,
                             detail: "Hold the modifier, type, then release to switch.")
        for (index, row) in [cycleRow, appCycleRow, alternateRow, searchRow, fastRow].enumerated() {
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            if index < 4 {
                let separator = NSBox()
                separator.boxType = .separator
                rows.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }

        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.maximumNumberOfLines = 3
        feedback.setAccessibilityIdentifier("shortcut-feedback")
        let defaults = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        defaults.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        saveButton.keyEquivalent = "\r"

        for view in [tabs, feedback, defaults, cancel, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        keyboardPage.addSubview(rows)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: feedback.topAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: keyboardPage.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: keyboardPage.trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: keyboardPage.topAnchor, constant: 6),
            feedback.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 36),
            feedback.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),
            defaults.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            defaults.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])
        keyboardLayoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.recording == nil else { return }
            self.renderDraft()
        }
    }

    private func recorder(for target: RecordingTarget) -> NSButton {
        switch target {
        case .cycle: return cycleRecorder
        case .appCycle: return appCycleRecorder
        case .alternateCycle: return alternateRecorder
        case .search: return searchRecorder
        }
    }

    private func pageStack(_ views: [NSView]) -> NSView {
        let page = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 24)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return page
    }

    private func description(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeGeneralPage() -> NSView {
        for control in [allDisplays, badges, sidebarEnabled, sidebarAutoHide, sidebarCurrentDisplay, gestureEnabled] {
            control.target = self
            control.action = #selector(preferenceChanged)
        }
        sidebarEdge.target = self
        sidebarEdge.action = #selector(preferenceChanged)
        allDisplays.setAccessibilityIdentifier("show-all-displays")
        restoreApp.target = self
        restoreApp.action = #selector(restoreIgnoredApp)
        restoreApp.bezelStyle = .rounded
        ignoredApps.setAccessibilityLabel("Excluded applications")
        let restoreRow = NSStackView(views: [ignoredApps, restoreApp])
        restoreRow.spacing = 8
        let ignoredHeading = NSTextField(labelWithString: "Excluded applications")
        ignoredHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        gestureFeedback.font = .systemFont(ofSize: 11)
        gestureFeedback.textColor = .secondaryLabelColor
        gestureFeedback.stringValue = gestureStatus
        return pageStack([allDisplays,
            description("The same query and selection appear on every screen. Turn this off to use only the display under the pointer."),
            badges, description("Badges come from the Dock when an app makes them available."),
            ignoredHeading, restoreRow,
            description("Right-click a window and choose Exclude Application. Select an app here to show it again."),
            gestureEnabled, description("Start with two fingers at a top corner of the trackpad, slide down, then lift to switch. Uses a private macOS interface; unsupported devices stay disabled."), gestureFeedback])
    }

    private func makeListsPage() -> NSView {
        listEditors = [WindowListSettingsView(title: "Main switcher and search"),
                       WindowListSettingsView(title: "Alternate switcher"),
                       WindowListSettingsView(title: "Sidebar")]
        for editor in listEditors { editor.onChange = { [weak self] in self?.readPreferences() } }
        editedList.addItems(withTitles: ["Main switcher and search", "Alternate switcher", "Sidebar"])
        editedList.target = self
        editedList.action = #selector(chooseList)
        editedList.setAccessibilityLabel("Window list to configure")
        let editors = NSStackView(views: listEditors)
        editors.orientation = .vertical
        editors.alignment = .leading
        editors.detachesHiddenViews = true
        chooseList()
        return pageStack([editedList, editors,
            description("Each list keeps its own filters. Current-app cycling uses the main switcher's filters."),
            description("Space filtering uses macOS window information. Windows with unknown Space membership remain included.")])
    }

    @objc private func chooseList() {
        for (index, editor) in listEditors.enumerated() { editor.isHidden = index != editedList.indexOfSelectedItem }
    }

    private func makeSidebarPage() -> NSView {
        sidebarEdge.addItems(withTitles: ["Left edge", "Right edge"])
        sidebarEdge.setAccessibilityLabel("Sidebar screen edge")
        let edgeRow = NSStackView(views: [NSTextField(labelWithString: "Position"), sidebarEdge])
        edgeRow.spacing = 12
        return pageStack([sidebarEnabled, description("A compact list of windows on each display. Click any window to switch."),
                          edgeRow, sidebarAutoHide, sidebarCurrentDisplay,
                          description("Move to the chosen screen edge to reveal a hidden Sidebar. Its Space headings and app badges use available macOS metadata.")])
    }

    private func renderPreferences() {
        allDisplays.state = preferences.showsOnAllDisplays ? .on : .off
        gestureEnabled.state = preferences.gestureEnabled ? .on : .off
        badges.state = preferences.showsBadges ? .on : .off
        sidebarEnabled.state = preferences.sidebarEnabled ? .on : .off
        sidebarAutoHide.state = preferences.sidebarAutoHide ? .on : .off
        sidebarCurrentDisplay.state = preferences.sidebarCurrentDisplayOnly ? .on : .off
        sidebarEdge.selectItem(at: preferences.sidebarEdge == .left ? 0 : 1)
        for (editor, policy) in zip(listEditors, [preferences.primaryList, preferences.alternateList, preferences.sidebarList]) { editor.load(policy) }
        ignoredApps.removeAllItems()
        for bundle in preferences.ignoredBundleIdentifiers {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent ?? bundle
            ignoredApps.addItem(withTitle: name)
            ignoredApps.lastItem?.representedObject = bundle
        }
        if ignoredApps.numberOfItems == 0 { ignoredApps.addItem(withTitle: "No excluded apps") }
        ignoredApps.isEnabled = !preferences.ignoredBundleIdentifiers.isEmpty
        restoreApp.isEnabled = ignoredApps.isEnabled
    }

    private func readPreferences() {
        preferences.showsOnAllDisplays = allDisplays.state == .on
        preferences.gestureEnabled = gestureEnabled.state == .on
        preferences.showsBadges = badges.state == .on
        preferences.sidebarEnabled = sidebarEnabled.state == .on
        preferences.sidebarAutoHide = sidebarAutoHide.state == .on
        preferences.sidebarCurrentDisplayOnly = sidebarCurrentDisplay.state == .on
        preferences.sidebarEdge = sidebarEdge.indexOfSelectedItem == 0 ? .left : .right
        if listEditors.count == 3 {
            preferences.primaryList = listEditors[0].policy
            preferences.alternateList = listEditors[1].policy
            preferences.sidebarList = listEditors[2].policy
        }
    }

    @objc private func preferenceChanged() { readPreferences() }

    @objc private func restoreIgnoredApp() {
        guard let bundle = ignoredApps.selectedItem?.representedObject as? String else { return }
        readPreferences()
        preferences.ignoredBundleIdentifiers.removeAll { $0 == bundle }
        renderPreferences()
    }

    private func configureRecorder(_ button: NSButton, action: Selector, label: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp("Press to record a keyboard shortcut. Escape cancels recording.")
    }

    private func recorderControls(_ recorder: NSButton, reset: NSButton, action: Selector, label: String) -> NSView {
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: label)
        reset.imagePosition = .imageOnly
        reset.bezelStyle = .inline
        reset.controlSize = .small
        reset.target = self
        reset.action = action
        reset.toolTip = label
        reset.setAccessibilityLabel(label)
        let controls = NSStackView(views: [recorder, reset])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        recorder.widthAnchor.constraint(equalToConstant: 142).isActive = true
        reset.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return controls
    }

    private func makeRow(_ checkbox: NSButton, control: NSView, detail: String) -> NSView {
        let row = NSView()
        let description = NSTextField(wrappingLabelWithString: detail)
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2
        checkbox.font = .systemFont(ofSize: 13)
        for view in [checkbox, description, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 76),
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: 172),
            description.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 19),
            description.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 4),
            description.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    private func renderDraft() {
        cycleEnabled.state = draft.cycleEnabled ? .on : .off
        appCycleEnabled.state = draft.appCycleEnabled ? .on : .off
        alternateEnabled.state = draft.alternateCycleEnabled ? .on : .off
        appCycleRecorder.title = shortcutDisplayName(draft.appCycle)
        alternateRecorder.title = shortcutDisplayName(draft.alternateCycle)
        appCycleRecorder.isEnabled = draft.appCycleEnabled
        alternateRecorder.isEnabled = draft.alternateCycleEnabled
        searchEnabled.state = draft.searchEnabled ? .on : .off
        fastEnabled.state = draft.fastSearchEnabled ? .on : .off
        cycleRecorder.title = shortcutDisplayName(draft.cycle)
        searchRecorder.title = shortcutDisplayName(draft.search)
        cycleRecorder.toolTip = "Record \(shortcutDisplayName(draft.cycle))"
        searchRecorder.toolTip = "Record \(shortcutDisplayName(draft.search))"
        cycleRecorder.isEnabled = draft.cycleEnabled
        searchRecorder.isEnabled = draft.searchEnabled
        fastModifier.isEnabled = draft.fastSearchEnabled
        if let index = modifiers.firstIndex(of: draft.fastSearchModifier) { fastModifier.selectItem(at: index) }
        renderPreferences()
        updateFeedback()
    }

    private func updateFeedback() {
        let error = draft.validationError()
        if recording != nil {
            feedback.stringValue = "Press your shortcut. Esc cancels recording."
            feedback.textColor = .secondaryLabelColor
        } else {
            feedback.stringValue = error ?? "macOS reserves some shortcuts. Use ↺ beside a shortcut to restore its default."
            feedback.textColor = error == nil ? .secondaryLabelColor : .systemRed
        }
        saveButton.isEnabled = recording == nil && error == nil
    }

    @objc private func updateEnabled() {
        finishRecording()
        draft.cycleEnabled = cycleEnabled.state == .on
        draft.appCycleEnabled = appCycleEnabled.state == .on
        draft.alternateCycleEnabled = alternateEnabled.state == .on
        draft.searchEnabled = searchEnabled.state == .on
        draft.fastSearchEnabled = fastEnabled.state == .on
        renderDraft()
    }

    @objc private func updateModifier() {
        finishRecording()
        let selected = fastModifier.indexOfSelectedItem
        guard modifiers.indices.contains(selected) else { return }
        draft.fastSearchModifier = modifiers[selected]
        renderDraft()
    }

    @objc private func recordCycle() { beginRecording(.cycle) }
    @objc private func recordAppCycle() { beginRecording(.appCycle) }
    @objc private func recordAlternate() { beginRecording(.alternateCycle) }
    @objc private func recordSearch() { beginRecording(.search) }

    private func beginRecording(_ target: RecordingTarget) {
        finishRecording()
        recording = target
        let button = recorder(for: target)
        button.title = "Type shortcut…"
        button.bezelColor = .controlAccentColor
        settingsWindow?.makeFirstResponder(button)
        ensureEventMonitor()
        updateFeedback()
    }

    private func ensureEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.settingsWindow?.isKeyWindow == true else { return event }
            return self.capture(event) ? nil : event
        }
    }

    @discardableResult
    private func capture(_ event: NSEvent) -> Bool {
        guard settingsWindow?.isKeyWindow == true else { return false }
        // A captured down event owns its whole key press. Keep repeats and the
        // matching up event away from app menus and default buttons after the
        // recorder has displayed the new shortcut.
        if (event.type == .keyDown || event.type == .keyUp), suppressedKeys.contains(event.keyCode) {
            if event.type == .keyUp {
                suppressedKeys.remove(event.keyCode)
                removeIdleEventMonitor()
            }
            return true
        }
        guard let target = recording else { return false }
        if event.type == .flagsChanged {
            let symbols = shortcutModifierSymbols(shortcutModifiers(event.modifierFlags))
            recorder(for: target).title = symbols.isEmpty ? "Type shortcut…" : symbols + "…"
            return true
        }
        if event.type == .keyUp { return true }
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            suppressedKeys.insert(event.keyCode)
            finishRecording()
            renderDraft()
            return true
        }
        guard !event.isARepeat else { return true }
        suppressedKeys.insert(event.keyCode)
        var modifiers = shortcutModifiers(event.modifierFlags)
        if KeyboardShortcut.hasImplicitFunctionFlag(keyCode: event.keyCode) { modifiers.remove(.fn) }
        let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
        switch target {
        case .cycle: draft.cycle = shortcut
        case .appCycle: draft.appCycle = shortcut
        case .alternateCycle: draft.alternateCycle = shortcut
        case .search: draft.search = shortcut
        }
        finishRecording()
        renderDraft()
        return true
    }

    private func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        let mask: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]
        return ShortcutModifiers(rawValue: UInt64(flags.intersection(mask).rawValue))
    }

    private func finishRecording(discardSuppressedKeys: Bool = false) {
        recording = nil
        if discardSuppressedKeys { suppressedKeys.removeAll() }
        removeIdleEventMonitor()
        cycleRecorder.title = shortcutDisplayName(draft.cycle)
        searchRecorder.title = shortcutDisplayName(draft.search)
        appCycleRecorder.title = shortcutDisplayName(draft.appCycle)
        alternateRecorder.title = shortcutDisplayName(draft.alternateCycle)
        for button in [cycleRecorder, appCycleRecorder, alternateRecorder, searchRecorder] { button.bezelColor = nil }
    }

    private func removeIdleEventMonitor() {
        guard recording == nil, suppressedKeys.isEmpty else { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    @objc private func restoreDefaults() {
        finishRecording()
        draft = .defaults
        preferences = .defaults
        renderDraft()
    }

    @objc private func restoreCycle() {
        finishRecording()
        draft.cycle = ShortcutConfiguration.defaults.cycle
        renderDraft()
    }

    @objc private func restoreAppCycle() { finishRecording(); draft.appCycle = ShortcutConfiguration.defaults.appCycle; renderDraft() }
    @objc private func restoreAlternate() { finishRecording(); draft.alternateCycle = ShortcutConfiguration.defaults.alternateCycle; renderDraft() }

    @objc private func restoreSearch() {
        finishRecording()
        draft.search = ShortcutConfiguration.defaults.search
        renderDraft()
    }

    @objc private func cancelSettings() {
        finishRecording()
        settingsWindow?.close()
    }

    @objc private func saveSettings() {
        guard recording == nil, draft.validationError() == nil else { updateFeedback(); return }
        readPreferences()
        onSave?(draft, preferences)
        settingsWindow?.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        finishRecording(discardSuppressedKeys: true)
        renderDraft()
    }

    func windowWillClose(_ notification: Notification) {
        finishRecording(discardSuppressedKeys: true)
        guard !closing else { return }
        closing = true
        onClose?()
    }
}


/// Consistent compact filters for each independently configured window list.
private final class WindowListSettingsView: NSView {
    var onChange: (() -> Void)?
    private let spaces = NSPopUpButton(frame: .zero, pullsDown: false)
    private let minimized = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hiddenPlacement = NSPopUpButton(frame: .zero, pullsDown: false)
    private let apps = NSButton(checkboxWithTitle: "Include apps without windows", target: nil, action: nil)
    private let scopes: [WindowListPolicy.SpaceScope] = [.all, .visibleAndFullScreen, .visible]
    private let placements: [WindowListPolicy.InactivePlacement] = [.normal, .bottom, .exclude]

    init(title: String) {
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        spaces.addItems(withTitles: ["All Spaces", "Visible + full-screen Spaces", "Visible Spaces"])
        minimized.addItems(withTitles: ["Normal order", "At the bottom", "Don't show"])
        hiddenPlacement.addItems(withTitles: ["Normal order", "At the bottom", "Don't show"])
        spaces.setAccessibilityLabel("\(title) Spaces")
        minimized.setAccessibilityLabel("\(title) minimized windows")
        hiddenPlacement.setAccessibilityLabel("\(title) hidden applications")
        for control in [spaces, minimized, hiddenPlacement] { control.target = self; control.action = #selector(changed) }
        apps.target = self; apps.action = #selector(changed)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Spaces"), spaces],
                                    [NSTextField(labelWithString: "Minimized"), minimized],
                                    [NSTextField(labelWithString: "Hidden apps"), hiddenPlacement]])
        grid.columnSpacing = 14
        grid.rowSpacing = 4
        let stack = NSStackView(views: [heading, grid, apps])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onChange?() }
    func load(_ policy: WindowListPolicy) {
        spaces.selectItem(at: scopes.firstIndex(of: policy.spaceScope) ?? 0)
        minimized.selectItem(at: placements.firstIndex(of: policy.minimized) ?? 0)
        hiddenPlacement.selectItem(at: placements.firstIndex(of: policy.hidden) ?? 0)
        apps.state = policy.includeApplicationsWithoutWindows ? .on : .off
    }
    var policy: WindowListPolicy {
        WindowListPolicy(spaceScope: scopes[max(0, spaces.indexOfSelectedItem)],
                         minimized: placements[max(0, minimized.indexOfSelectedItem)],
                         hidden: placements[max(0, hiddenPlacement.indexOfSelectedItem)],
                         includeApplicationsWithoutWindows: apps.state == .on)
    }
}
