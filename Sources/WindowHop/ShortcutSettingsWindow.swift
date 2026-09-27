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
    var onSave: ((ShortcutConfiguration) -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { settingsWindow?.isVisible ?? false }

    private enum RecordingTarget { case cycle, search }
    private var settingsWindow: ShortcutRecordingWindow?
    private var draft = ShortcutConfiguration.defaults
    private var recording: RecordingTarget?
    private var eventMonitor: Any?
    private var suppressedKeys = Set<UInt16>()
    private var keyboardLayoutObserver: NSObjectProtocol?
    private var closing = false
    private let cycleEnabled = NSButton(checkboxWithTitle: "Window switching", target: nil, action: nil)
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

    func show(configuration: ShortcutConfiguration) {
        if isVisible {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        draft = configuration
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 416),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "WindowHop Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.captureKeyEquivalent = { [weak self] event in self?.capture(event) ?? false }
        settingsWindow = window
        guard let content = window.contentView else { return }

        let heading = NSTextField(labelWithString: "Keyboard shortcuts")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0

        configureRecorder(cycleRecorder, action: #selector(recordCycle), label: "Window switching shortcut")
        configureRecorder(searchRecorder, action: #selector(recordSearch), label: "Search windows shortcut")
        cycleEnabled.target = self
        cycleEnabled.action = #selector(updateEnabled)
        searchEnabled.target = self
        searchEnabled.action = #selector(updateEnabled)
        fastEnabled.target = self
        fastEnabled.action = #selector(updateEnabled)
        fastModifier.addItems(withTitles: modifiers.map(\.displayName))
        fastModifier.target = self
        fastModifier.action = #selector(updateModifier)
        fastModifier.setAccessibilityLabel("Fast Search modifier")

        let cycleControls = recorderControls(cycleRecorder, reset: cycleReset,
                                              action: #selector(restoreCycle),
                                              label: "Restore Command-Tab")
        let searchControls = recorderControls(searchRecorder, reset: searchReset,
                                               action: #selector(restoreSearch),
                                               label: "Restore Control-Space")
        let cycleRow = makeRow(cycleEnabled, control: cycleControls,
                               detail: "Add Shift to go backward. Release to switch.")
        let searchRow = makeRow(searchEnabled, control: searchControls,
                                detail: "Type a window name, then press Return.")
        let fastRow = makeRow(fastEnabled, control: fastModifier,
                             detail: "Hold the modifier, type, then release to switch.")
        for (index, row) in [cycleRow, searchRow, fastRow].enumerated() {
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            if index < 2 {
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

        for view in [heading, rows, feedback, defaults, cancel, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            rows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            rows.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            feedback.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            feedback.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 12),
            feedback.bottomAnchor.constraint(lessThanOrEqualTo: saveButton.topAnchor, constant: -12),
            defaults.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
            defaults.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
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
    @objc private func recordSearch() { beginRecording(.search) }

    private func beginRecording(_ target: RecordingTarget) {
        finishRecording()
        recording = target
        let button = target == .cycle ? cycleRecorder : searchRecorder
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
            (target == .cycle ? cycleRecorder : searchRecorder).title = symbols.isEmpty ? "Type shortcut…" : symbols + "…"
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
        cycleRecorder.bezelColor = nil
        searchRecorder.bezelColor = nil
    }

    private func removeIdleEventMonitor() {
        guard recording == nil, suppressedKeys.isEmpty else { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    @objc private func restoreDefaults() {
        finishRecording()
        draft = .defaults
        renderDraft()
    }

    @objc private func restoreCycle() {
        finishRecording()
        draft.cycle = ShortcutConfiguration.defaults.cycle
        renderDraft()
    }

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
        onSave?(draft)
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
