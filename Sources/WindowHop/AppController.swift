import AppKit
import ApplicationServices
import WindowHopCore

final class AppController: NSObject, NSApplicationDelegate {
    private let index = WindowIndex()
    private let keyboard = KeyboardController()
    private let panel = SwitcherPanels()
    private let sidebar = SidebarController()
    private let gestures = TrackpadGestureController()
    private var gestureActive = false
    private let settings = ShortcutSettingsWindow()
    private let defaults = UserDefaults.standard
    private var session = SwitcherSession()
    private var statusItem: NSStatusItem!
    private var shortcutsItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var timer: Timer?
    private var statusMessage = ""
    private var learned: [String: String] = [:]
    private var wasTrusted = false
    private var demo = CommandLine.arguments.contains("--demo")
    private let diagnose = CommandLine.arguments.contains("--diagnose")
    private var pendingRefresh = false
    private var pendingReverse = false
    private var focusGeneration = UUID()
    private var shortcuts = ShortcutConfiguration.defaults
    private var settingsOpen = false
    private var preferences = WindowHopPreferences.defaults
    private enum SwitcherProfile { case primary, currentApplication, alternate }
    private var activeProfile: SwitcherProfile = .primary
    private var invocationApplication: Int32?
    private var invocationScreen: NSScreen?
    private var cycleSearchActive = false
    private var demoRemovedIDs = Set<String>()
    private var cycleLabel = "⌘⇥"
    private var fastSearchLabel = "Right Option"

    private var keyboardEnabled: Bool {
        get { defaults.bool(forKey: "keyboardEnabled") }
        set { defaults.set(newValue, forKey: "keyboardEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["commandTabEnabled": true, "fastSearchModifier": "rightOption"])
        learned = defaults.dictionary(forKey: "learnedSearches") as? [String: String] ?? [:]
        configureMenu()
        configureMainMenu()
        configureCallbacks()
        loadShortcuts()
        loadPreferences()
        if diagnose {
            index.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
                print("Indexed windows: \(self.index.windows.count)")
                print("Keyboard interception: disabled for diagnostic run")
                NSApp.terminate(nil)
            }
            return
        }
        if demo {
            statusMessage = "Demo mode: no global shortcuts or window activation"
            begin(.search)
        } else {
            index.start()
            updateAvailability()
            if !AXIsProcessTrusted() { begin(.search) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateAvailability() }
        updateMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
        sidebar.stop()
        gestures.enabled = false
        index.stop()
        timer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsOpen { showSettings(); return false }
        begin(.search)
        return false
    }

    private func configureCallbacks() {
        settings.onSave = { [weak self] configuration, preferences in
            guard let self, configuration.validationError() == nil else { return }
            self.applyShortcuts(configuration)
            self.applyPreferences(preferences)
            if let data = try? JSONEncoder().encode(configuration) {
                self.defaults.set(data, forKey: "shortcutConfiguration")
            }
        }
        settings.onClose = { [weak self] in
            guard let self else { return }
            self.settingsOpen = false
            self.updateSidebar()
            self.statusMessage = ""
            self.updateAvailability()
        }
        keyboard.onAction = { [weak self] action in self?.handle(action) }
        keyboard.onFailure = { [weak self] message in
            guard let self else { return }
            self.cancel(preserveKeyboardState: true)
            self.statusMessage = message
            self.updateMenu()
        }
        index.onChange = { [weak self] windows in
            guard let self else { return }
            if !self.demo {
                self.session.prepare(windows: self.filteredWindows(windows), preferences: self.learned, shortcutWindows: windows)
                self.panel.prepare(windows: windows)
            }
            if self.pendingRefresh, self.session.mode != nil {
                self.pendingRefresh = false
                let mode = self.session.mode!
                let query = self.session.query
                self.session.begin(mode: mode, windows: self.filteredWindows(windows), preferences: self.learned, reverse: self.pendingReverse, shortcutWindows: windows)
                if mode != .cycle || !query.isEmpty { self.session.updateQuery(query, preferences: self.learned) }
                self.render()
            } else if self.session.mode != nil, !self.demo {
                let live = Set(self.filteredWindows(windows).map(\.id))
                for item in self.session.windows where !live.contains(item.id) { self.session.removeWindow(id: item.id) }
                self.render()
            }
            self.updateSidebar()
            // Do not replace a live session's order. Closed entries are checked on activation.
            self.updateMenu()
        }
        index.onStatus = { [weak self] message in
            self?.statusMessage = message
            self?.updateMenu()
        }
        panel.onQuery = { [weak self] query in
            guard let self else { return }
            self.session.updateQuery(query, preferences: self.demo ? [:] : self.learned)
            self.render()
        }
        panel.onMove = { [weak self] delta in self?.move(delta) }
        panel.onSelection = { [weak self] row in
            guard let self else { return }
            self.session.move(row - self.session.selectedIndex)
            self.render()
        }
        panel.onCommit = { [weak self] in self?.commit() }
        panel.onQuickSelect = { [weak self] index in self?.selectAndCommit(index) }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onOpenSettings = { [weak self] in self?.requestPermission() }
        panel.onCloseSelected = { [weak self] in self?.perform(.close) }
        panel.onMinimizeSelected = { [weak self] in self?.perform(.minimize) }
        panel.onHideSelectedApp = { [weak self] in self?.perform(.hideApplication) }
        panel.onQuitSelectedApp = { [weak self] in self?.perform(.quitApplication) }
        panel.onExcludeApplication = { [weak self] in self?.exclude($0) }
        gestures.onBegin = { [weak self] in
            guard let self else { return }
            guard self.session.mode == nil, !self.settingsOpen else {
                if self.gestureActive { self.cancel(preserveKeyboardState: true) }
                else { self.gestures.cancel() }
                return
            }
            self.gestureActive = true
            self.begin(.cycle, fromKeyboard: true, fromGesture: true)
        }
        gestures.onMove = { [weak self] amount in
            guard let self, self.gestureActive else { return }
            self.move(amount)
        }
        gestures.onCommit = { [weak self] in
            guard let self, self.gestureActive else { return }
            self.gestureActive = false
            self.commit(fromKeyboard: true)
        }
        gestures.onCancel = { [weak self] in
            guard let self, self.gestureActive else { return }
            self.cancel(preserveKeyboardState: true)
        }
        sidebar.onSelect = { [weak self] in self?.activateFromSidebar($0) }
        sidebar.onClose = { [weak self] in self?.perform(.close, on: $0) }
        sidebar.onMinimize = { [weak self] in self?.perform(.minimize, on: $0) }
        sidebar.onHide = { [weak self] in self?.perform(.hideApplication, on: $0) }
        sidebar.onQuit = { [weak self] in self?.perform(.quitApplication, on: $0) }
        sidebar.onExclude = { [weak self] in self?.exclude($0) }
        sidebar.onHideSidebar = { [weak self] in
            guard let self else { return }
            self.preferences.sidebarEnabled = false
            self.applyPreferences(self.preferences)
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WindowHop")
        statusItem.button?.toolTip = "WindowHop"
        let menu = NSMenu()
        add("Search Windows…", action: #selector(searchWindows), to: menu)
        add("Refresh Windows", action: #selector(refreshWindows), to: menu)
        add("Preview Sample Windows", action: #selector(previewDemo), to: menu)
        menu.addItem(.separator())
        shortcutsItem = add("Enable Keyboard Shortcuts", action: #selector(toggleShortcuts), to: menu)
        add("Settings…", action: #selector(showSettings), to: menu, key: ",")
        menu.addItem(.separator())
        add("Open Accessibility Settings…", action: #selector(requestPermission), to: menu)
        add("Forget Learned Searches", action: #selector(forgetSearches), to: menu)
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        add("Quit WindowHop", action: #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "WindowHop", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "WindowHop")
        add("Settings…", action: #selector(showSettings), to: appMenu, key: ",")
        appMenu.addItem(.separator())
        add("Search Windows…", action: #selector(searchWindows), to: appMenu, key: "f")
        let preview = add("Preview Sample Windows", action: #selector(previewDemo), to: appMenu, key: "d")
        preview.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        add("Quit WindowHop", action: #selector(quit), to: appMenu, key: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                        ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                        ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func updateMenu() {
        shortcutsItem.state = keyboardEnabled && !demo ? .on : .off
        shortcutsItem.isEnabled = !demo
        if demo { statusMenuItem.title = "Demo mode" }
        else if settingsOpen { statusMenuItem.title = "Shortcuts paused while settings are open" }
        else if !AXIsProcessTrusted() { statusMenuItem.title = "Accessibility access needed" }
        else if !statusMessage.isEmpty { statusMenuItem.title = statusMessage }
        else { statusMenuItem.title = "\(index.windows.count) windows · \(keyboard.isRunning ? "shortcuts on" : "shortcuts off")" }
        statusItem.button?.toolTip = "WindowHop · \(statusMenuItem.title)"
    }

    private func updateAvailability() {
        let trusted = AXIsProcessTrusted()
        if trusted && !wasTrusted { index.refresh(); statusMessage = "" }
        if !trusted && wasTrusted { keyboard.stop(); cancel() }
        wasTrusted = trusted
        let hasBindings = shortcuts.cycleEnabled || shortcuts.appCycleEnabled || shortcuts.alternateCycleEnabled || shortcuts.searchEnabled || shortcuts.fastSearchEnabled
        if keyboard.isRunning && (settingsOpen || !hasBindings) { keyboard.stop(); cancel() }
        if keyboardEnabled, trusted, !keyboard.isRunning, !demo, !settingsOpen, hasBindings {
            if contextsRunning {
                statusMessage = "Quit Contexts before enabling WindowHop shortcuts"
            } else if keyboard.start() {
                statusMessage = ""
            }
        }
        if keyboard.isRunning, contextsRunning {
            keyboard.stop()
            cancel()
            statusMessage = "Shortcuts paused while Contexts is running"
        }
        updateGestureAvailability()
        updateMenu()
    }

    private func updateGestureAvailability() {
        gestures.enabled = preferences.gestureEnabled && AXIsProcessTrusted() && !diagnose && !demo && !settingsOpen && !contextsRunning
        if !preferences.gestureEnabled { settings.gestureStatus = "Gesture switching is off." }
        else if !AXIsProcessTrusted() { settings.gestureStatus = "Accessibility access is required." }
        else if contextsRunning { settings.gestureStatus = "Paused while Contexts is running." }
        else if settingsOpen { settings.gestureStatus = "Gesture capture resumes after Settings closes." }
        else { settings.gestureStatus = gestures.status }
    }

    private var contextsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased() == "contexts" || ($0.bundleIdentifier?.lowercased().contains("contexts") == true)
        }
    }

    private func handle(_ action: KeyboardAction) {
        guard !settingsOpen else { return }
        switch action {
        case .beginCycle(let reverse): begin(.cycle, reverse: reverse, fromKeyboard: true)
        case .beginAppCycle(let reverse): begin(.cycle, reverse: reverse, fromKeyboard: true, profile: .currentApplication)
        case .beginAlternateCycle(let reverse): begin(.cycle, reverse: reverse, fromKeyboard: true, profile: .alternate)
        case .beginCycleSearch:
            guard session.mode == .cycle else { return }
            cycleSearchActive = true
            session.enterCycleSearch()
            panel.show(mode: .fastSearch, screen: invocationScreen, demo: demo)
            render()
        case .closeSelected: perform(.close)
        case .minimizeSelected: perform(.minimize)
        case .hideSelectedApp: perform(.hideApplication)
        case .quitSelectedApp: perform(.quitApplication)
        case .cycle(let reverse): move(reverse ? -1 : 1)
        case .showSearch: begin(.search, fromKeyboard: true)
        case .beginFastSearch(let text):
            begin(.fastSearch, fromKeyboard: true)
            session.updateQuery(text, preferences: demo ? [:] : learned)
            render()
        case .appendText(let text): session.updateQuery(session.query + text, preferences: demo ? [:] : learned); render()
        case .deleteBackward:
            if !session.query.isEmpty { session.updateQuery(String(session.query.dropLast()), preferences: demo ? [:] : learned) }
            render()
        case .move(let amount): move(amount)
        case .selectAndCommit(let index): selectAndCommit(index, fromKeyboard: true)
        case .commit: commit(fromKeyboard: true)
        case .cancel: cancel(preserveKeyboardState: true)
        }
    }

    private func begin(_ mode: SwitcherSession.Mode, reverse: Bool = false, fromKeyboard: Bool = false, profile: SwitcherProfile = .primary, fromGesture: Bool = false) {
        guard !settingsOpen else { return }
        focusGeneration = UUID()
        index.cancelPendingActivation()
        if !fromGesture { gestures.cancel(); gestureActive = false }
        activeProfile = profile
        cycleSearchActive = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        invocationApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? index.windows.first?.processIdentifier : frontmost?.processIdentifier
        if panel.isVisible { panel.hide() }
        let windows = filteredWindows(demo ? Self.demoWindows.filter { !demoRemovedIDs.contains($0.id) } : (AXIsProcessTrusted() ? index.windows : []))
        if demo { panel.prepare(windows: windows); session.prepare(windows: windows, shortcutWindows: availableWindows) }
        pendingRefresh = windows.isEmpty && AXIsProcessTrusted() && !demo
        pendingReverse = reverse
        session.begin(mode: mode, windows: windows, preferences: demo ? [:] : learned, reverse: reverse, shortcutWindows: availableWindows)
        if !fromKeyboard {
            switch mode {
            case .cycle: keyboard.mode = .cycle
            case .search: keyboard.mode = .search
            case .fastSearch: keyboard.mode = .fastSearch
            }
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        invocationScreen = screen
        sidebar.suspended = true
        panel.show(mode: mode, screen: screen, demo: demo)
        render()
        if mode == .search { keyboard.searchFieldReady() }
        if pendingRefresh { index.refresh() }
    }

    private func move(_ amount: Int) { session.move(amount); render() }

    private func render() {
        guard let mode = session.mode else { return }
        keyboard.resultCount = session.results.count
        let missingPermission = !demo && !AXIsProcessTrusted()
        let emptyMessage: String
        if missingPermission { emptyMessage = "Allow WindowHop to read and focus your windows in Accessibility settings." }
        else if pendingRefresh { emptyMessage = "Finding your windows…" }
        else if session.query.isEmpty { emptyMessage = "No windows found. Open an application window, then choose Refresh Windows." }
        else { emptyMessage = "No matching windows. Try an app name or a few letters from its title." }
        let hint: String
        if gestureActive { hint = "Slide to select · Lift fingers to switch · Esc cancels" }
        else if demo { hint = "Demo windows · Type a code or title · ⌘1–9 / Return preview · Esc closes" }
        else if missingPermission { hint = "Accessibility access needed" }
        else {
            switch mode {
            case .cycle: hint = "\(session.results.count) windows · \(activeCycleLabel) cycles · ⌘S searches · ⌘W close · ⌘M minimize · Esc cancels"
            case .search: hint = "\(session.results.count) windows · Type a code or title · ⌘1–9 / Return switches · Esc cancels"
            case .fastSearch: hint = "\(session.results.count) matches · Type a code or title · Release \(cycleSearchActive ? activeCycleLabel : fastSearchLabel) to switch · Esc cancels"
            }
        }
        panel.render(session, footer: hint, emptyMessage: emptyMessage, needsPermission: missingPermission)
    }

    private func commit(fromKeyboard: Bool = false) {
        guard let selected = session.selected else { cancel(preserveKeyboardState: fromKeyboard); return }
        let query = SearchEngine.normalizedQuery(session.query)
        let usedAssignedCode = session.isSearchShortcut(query, forWindowID: selected.id)
        cancel(preserveKeyboardState: fromKeyboard)
        let request = focusGeneration
        if demo {
            statusMessage = "Demo selected: \(selected.appName)"
            updateMenu()
            return
        }
        index.activate(selected) { [weak self] result in
            guard let self, self.focusGeneration == request else { return }
            switch result {
            case .success:
                self.statusMessage = ""
                // Generated codes identify this live window. Learning them by
                // title would steal a duplicate's code or break on title changes.
                if !usedAssignedCode && !query.isEmpty && query.count <= 3 {
                    if self.learned.count >= 128, let key = self.learned.keys.sorted().first { self.learned.removeValue(forKey: key) }
                    self.learned[query] = SearchEngine.preferenceKey(for: selected)
                    self.defaults.set(self.learned, forKey: "learnedSearches")
                    self.session.prepare(windows: self.filteredWindows(self.index.windows), preferences: self.learned, shortcutWindows: self.index.windows)
                }
            case .failure(let error):
                self.statusMessage = error.localizedDescription
                NSSound.beep()
            }
            self.updateMenu()
        }
    }

    private func selectAndCommit(_ index: Int, fromKeyboard: Bool = false) {
        guard session.mode != nil else { return }
        guard session.results.indices.contains(index) else {
            // A window may close between capture and delivery. The tap has
            // already ended this gesture; do not leave an unarmed panel open.
            if fromKeyboard { cancel(preserveKeyboardState: true) }
            return
        }
        session.move(index - session.selectedIndex)
        commit(fromKeyboard: fromKeyboard)
    }

    private func cancel(preserveKeyboardState: Bool = false) {
        gestures.cancel()
        gestureActive = false
        focusGeneration = UUID()
        index.cancelPendingActivation()
        pendingRefresh = false
        panel.hide()
        session.end()
        cycleSearchActive = false
        updateSidebar()
        keyboard.resultCount = 0
        if !preserveKeyboardState { keyboard.mode = .hidden }
    }

    @objc private func searchWindows() {
        guard !settingsOpen else { showSettings(); return }
        if demo { demo = false; statusMessage = ""; index.start(); updateAvailability() }
        begin(.search)
    }
    @objc private func previewDemo() {
        guard !settingsOpen else { showSettings(); return }
        cancel()
        keyboard.stop()
        demo = true
        updateGestureAvailability()
        demoRemovedIDs.removeAll()
        begin(.search)
        updateMenu()
    }
    @objc private func refreshWindows() { index.refresh() }
    @objc private func toggleShortcuts() {
        guard !demo else { return }
        if !AXIsProcessTrusted() { requestPermission(); return }
        keyboardEnabled.toggle()
        if !keyboardEnabled { keyboard.stop(); cancel(); statusMessage = "" }
        updateAvailability()
    }
    @objc private func showSettings() {
        guard !settingsOpen else { settings.show(configuration: shortcuts, preferences: preferences); return }
        cancel()
        settingsOpen = true
        updateGestureAvailability()
        sidebar.suspended = true
        keyboard.stop()
        settings.show(configuration: shortcuts, preferences: preferences)
        updateMenu()
    }

    private var activeCycleLabel: String {
        switch activeProfile {
        case .primary: return cycleLabel
        case .currentApplication: return shortcutDisplayName(shortcuts.appCycle)
        case .alternate: return shortcutDisplayName(shortcuts.alternateCycle)
        }
    }

    private var availableWindows: [WindowItem] { demo ? Self.demoWindows.filter { !demoRemovedIDs.contains($0.id) } : index.windows }

    private func filteredWindows(_ windows: [WindowItem]) -> [WindowItem] {
        let ignored = Set(preferences.ignoredBundleIdentifiers)
        var policy = activeProfile == .alternate ? preferences.alternateList : preferences.primaryList
        policy.currentApplicationOnly = activeProfile == .currentApplication
        return policy.apply(to: windows.filter { !ignored.contains($0.bundleIdentifier) },
                            frontmostProcessIdentifier: invocationApplication)
    }

    private func loadPreferences() {
        if let data = defaults.data(forKey: "windowPreferences"),
           let saved = try? JSONDecoder().decode(WindowHopPreferences.self, from: data) { preferences = saved }
        applyPreferences(preferences)
    }

    private func applyPreferences(_ preferences: WindowHopPreferences) {
        self.preferences = preferences
        panel.showsOnAllDisplays = preferences.showsOnAllDisplays
        panel.showsBadges = preferences.showsBadges
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "windowPreferences") }
        session.prepare(windows: filteredWindows(index.windows), preferences: learned, shortcutWindows: index.windows)
        updateGestureAvailability()
        updateSidebar()
    }

    private func updateSidebar() {
        sidebar.suspended = diagnose || settingsOpen || session.mode != nil || (!demo && !AXIsProcessTrusted())
        sidebar.update(windows: availableWindows, preferences: preferences)
    }

    private func exclude(_ item: WindowItem) {
        guard !item.bundleIdentifier.isEmpty else { return }
        if !preferences.ignoredBundleIdentifiers.contains(item.bundleIdentifier) {
            preferences.ignoredBundleIdentifiers.append(item.bundleIdentifier)
        }
        for candidate in session.windows where candidate.bundleIdentifier == item.bundleIdentifier { session.removeWindow(id: candidate.id) }
        applyPreferences(preferences)
        render()
    }

    private func perform(_ action: WindowIndex.WindowAction, on item: WindowItem? = nil) {
        guard let selected = item ?? session.selected else { return }
        if demo {
            let affected = (action == .hideApplication || action == .quitApplication)
                ? availableWindows.filter { $0.bundleIdentifier == selected.bundleIdentifier } : [selected]
            for window in affected { demoRemovedIDs.insert(window.id); session.removeWindow(id: window.id) }
            updateSidebar()
            render()
            return
        }
        let generation = focusGeneration
        index.perform(action, on: selected) { [weak self] result in
            guard let self, self.focusGeneration == generation else { return }
            if case .failure(let error) = result { self.statusMessage = error.localizedDescription; NSSound.beep() }
            else { self.statusMessage = "" }
            self.updateMenu()
        }
    }

    private func activateFromSidebar(_ item: WindowItem) {
        if demo { statusMessage = "Demo selected: \(item.appName)"; updateMenu(); return }
        cancel()
        let generation = focusGeneration
        index.activate(item) { [weak self] result in
            guard let self, self.focusGeneration == generation else { return }
            if case .failure(let error) = result { self.statusMessage = error.localizedDescription; NSSound.beep() }
            else { self.statusMessage = "" }
            self.updateMenu()
        }
    }

    private func loadShortcuts() {
        if let data = defaults.data(forKey: "shortcutConfiguration"),
           let saved = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
           saved.validationError() == nil {
            applyShortcuts(saved)
        } else {
            var migrated = ShortcutConfiguration.defaults
            migrated.cycleEnabled = defaults.bool(forKey: "commandTabEnabled")
            migrated.fastSearchModifier = FastSearchModifier(rawValue: defaults.string(forKey: "fastSearchModifier") ?? "") ?? .rightOption
            applyShortcuts(migrated)
        }
    }

    private func applyShortcuts(_ configuration: ShortcutConfiguration) {
        shortcuts = configuration
        keyboard.configuration = configuration
        let bindings: [(Bool, KeyboardShortcut)] = [
            (configuration.cycleEnabled, configuration.cycle),
            (configuration.appCycleEnabled, configuration.appCycle),
            (configuration.alternateCycleEnabled, configuration.alternateCycle),
            (configuration.searchEnabled, configuration.search)
        ]
        panel.reservedCommandKeyCodes = Set(bindings.compactMap { enabled, shortcut in
            enabled && shortcut.modifiers == .command ? shortcut.keyCode : nil
        })
        // Translate key labels only when settings change, never during selection.
        cycleLabel = shortcutDisplayName(configuration.cycle)
        fastSearchLabel = configuration.fastSearchModifier.displayName
    }
    @objc private func forgetSearches() {
        learned = [:]
        defaults.removeObject(forKey: "learnedSearches")
        session.prepare(windows: filteredWindows(availableWindows), shortcutWindows: availableWindows)
    }
    @objc private func requestPermission() {
        cancel()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private static let demoWindows: [WindowItem] = [
        WindowItem(id: "demo-code", appName: "Xcode", title: "WindowHop — AppController.swift", bundleIdentifier: "com.apple.dt.Xcode"),
        WindowItem(id: "demo-browser", appName: "Safari", title: "Contexts — Window switching", bundleIdentifier: "com.apple.Safari"),
        WindowItem(id: "demo-terminal", appName: "Terminal", title: "windowhop — swift test", bundleIdentifier: "com.apple.Terminal"),
        WindowItem(id: "demo-finder", appName: "Finder", title: "Projects", bundleIdentifier: "com.apple.finder"),
        WindowItem(id: "demo-notes", appName: "Notes", title: "Ideas for the week", bundleIdentifier: "com.apple.Notes"),
        WindowItem(id: "demo-safari2", appName: "Safari", title: "Accessibility API documentation", bundleIdentifier: "com.apple.Safari", isMinimized: true),
        WindowItem(id: "demo-chrome", appName: "Google Chrome", title: "WindowHop README", bundleIdentifier: "com.google.Chrome"),
        WindowItem(id: "demo-mail", appName: "Mail", title: "Inbox", bundleIdentifier: "com.apple.mail"),
        WindowItem(id: "demo-messages", appName: "Messages", title: "Weekend plans", bundleIdentifier: "com.apple.MobileSMS"),
        WindowItem(id: "demo-emacs", appName: "Emacs", title: "Scratch buffer", bundleIdentifier: "org.gnu.Emacs"),
        WindowItem(id: "demo-firefox", appName: "Firefox", title: "Extension documentation", bundleIdentifier: "org.mozilla.firefox"),
        WindowItem(id: "demo-downloads", appName: "Finder", title: "Downloads", bundleIdentifier: "com.apple.finder"),
        WindowItem(id: "demo-reading", appName: "Notes", title: "Reading list", bundleIdentifier: "com.apple.Notes"),
        WindowItem(id: "demo-calendar", appName: "Calendar", title: "This week", bundleIdentifier: "com.apple.iCal"),
        WindowItem(id: "demo-music", appName: "Music", title: "Library", bundleIdentifier: "com.apple.Music"),
        WindowItem(id: "demo-reminders", appName: "Reminders", title: "Today", bundleIdentifier: "com.apple.reminders"),
        WindowItem(id: "demo-preview", appName: "Preview", title: "Architecture sketch", bundleIdentifier: "com.apple.Preview"),
        WindowItem(id: "demo-swift", appName: "Safari", title: "Swift documentation", bundleIdentifier: "com.apple.Safari"),
        WindowItem(id: "demo-build", appName: "Terminal", title: "Build log", bundleIdentifier: "com.apple.Terminal"),
        WindowItem(id: "demo-core", appName: "Xcode", title: "WindowHopCore.swift", bundleIdentifier: "com.apple.dt.Xcode"),
        WindowItem(id: "demo-documents", appName: "Finder", title: "Documents", bundleIdentifier: "com.apple.finder"),
        WindowItem(id: "demo-weekend", appName: "Notes", title: "Ideas for the weekend", bundleIdentifier: "com.apple.Notes"),
        WindowItem(id: "demo-release", appName: "Safari", title: "Release notes", bundleIdentifier: "com.apple.Safari"),
        WindowItem(id: "demo-work", appName: "Finder", title: "Work", bundleIdentifier: "com.apple.finder")
    ]
}
