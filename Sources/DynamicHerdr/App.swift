import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import IslandCore
import SwiftTerm

@main
struct DynamicHerdrApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class IslandHostingView: NSHostingView<IslandView> {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: IslandModel!
    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var autoCollapse: Task<Void, Never>?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var settingsWindow: NSWindow?
    private let presentation = NotchPresentation()
    private var keyboard = IslandKeyboard()
    private var finishAnimation: Task<Void, Never>?
    private var transitionID = 0
    private var returnApplication: NSRunningApplication?
    private var openingSettings = false
    private let notificationSound = NSSound(named: "Pop")
    private var lastShortcutAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        model = IslandModel(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--snapshot"))
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = IslandHostingView(rootView: IslandView(model: model, presentation: presentation))
        host.sizingOptions = []
        panel.contentView = host
        panel.title = "Herdr Island"
        panel.delegate = self
        updateGeometry()

        if CommandLine.arguments.contains("--layout-report") {
            let g = presentation.geometry
            print("Notch: \(g.hasNotch); screen: \(g.screen); center: \(g.centerX); housing: \(g.notchWidth) × \(g.notchHeight); expanded: \(g.panelFrame(from: .expanded, to: .expanded))")
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Herdr Island")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.onPresent = { [weak self] in self?.present() }
        model.onNotification = { [weak self] in self?.present(notification: true) }
        model.onCollapse = { [weak self] in self?.collapse() }
        model.onChange = { [weak self] in self?.updateStatus() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onTerminalFocus = { [weak self] in self?.focusIsland(resetResponder: false) }

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.expanded else { return }
                self.model.collapse()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let input = self.keyInput(event)
            if input.key == "space", input.modifiers == [.control, .option] {
                if !event.isARepeat { self.shortcutInvoked() }
                return nil
            }
            if event.window === self.settingsWindow {
                if input.key == "escape" || (input.key == "w" && input.modifiers == .command) {
                    self.settingsWindow?.close(); return nil
                }
                return event
            }
            guard event.window === self.panel, self.panel.isKeyWindow, self.model.expanded else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if let terminal = self.panel.firstResponder as? TerminalView, terminal.hasMarkedText() { return event }
            if self.model.addingAgent {
                if !self.model.launchingAgent, input.modifiers == .command, ["1", "2", "3"].contains(input.key) {
                    self.model.newAgentKind = input.key == "1" ? "claude" : input.key == "2" ? "codex" : "terminal"; return nil
                }
                if input.key == "escape" { self.model.cancelAddingAgent(); return nil }
                if input.key == "return", input.modifiers == .command { self.model.launchAgent(); return nil }
                if self.model.newAgentKey?(input) == true { return nil }
                return event
            }
            if self.model.isHome, input.key == "n", input.modifiers == .command {
                self.model.beginAddingAgent(); return nil
            }
            let command = self.keyboard.route(input, context: KeyboardContext(help: self.model.showingHelp, home: self.model.isHome))
            if self.model.prefixPending != self.keyboard.prefixPending { self.model.prefixPending = self.keyboard.prefixPending }
            if command == .passThrough { return event }
            self.handle(command)
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged), name: NSWorkspace.didWakeNotification, object: nil)
        registerShortcut()
        panel.setFrame(presentation.geometry.panelFrame(from: .hidden, to: .hidden), display: false)
        model.start()

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            Task {
                await model.refresh()
                if CommandLine.arguments.contains("--completion"), let item = model.items.first(where: { $0.agent.agentStatus == .done }) {
                    model.select(item.agent)
                }
                if !CommandLine.arguments.contains("--compact") { model.expand() }
                if CommandLine.arguments.contains("--home-view") { model.showHome() }
                if CommandLine.arguments.contains("--new-agent-view") { model.beginAddingAgent() }
                if CommandLine.arguments.contains("--help-view") { model.showingHelp = true }
                transitionID += 1
                finishAnimation?.cancel()
                presentation.setPhase(model.expanded ? .expanded : .compact, animated: false)
                panel.setFrame(presentation.geometry.panelFrame(from: presentation.phase, to: presentation.phase), display: true)
                panel.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(600))
                saveSnapshot(path: path)
                NSApp.terminate(nil)
            }
        } else if model.demo || CommandLine.arguments.contains("--open") {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await model.refresh()
                openInbox()
            }
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Herdr Island")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Herdr Island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; appMenu.addItem(quit)
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if model.expanded && panel.isVisible { model.collapse() }
        else { openInbox() }
    }

    private func present(notification: Bool = false) {
        guard settingsWindow?.isVisible != true else { return }
        autoCollapse?.cancel()
        transition(to: model.expanded ? .expanded : .compact)
        if notification, !model.expanded, !model.isPaused,
           !CommandLine.arguments.contains("--snapshot"),
           UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true {
            notificationSound?.volume = 0.65
            notificationSound?.stop()
            notificationSound?.play()
        }
        if !model.expanded {
            autoCollapse = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, !self.model.expanded else { return }
                self.transition(to: .hidden)
            }
        }
    }

    private func collapse() {
        autoCollapse?.cancel()
        keyboard.reset()
        model.keyboardActive = false
        panel.resignKey()
        if !openingSettings, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            returnApplication?.activate()
        }
        transition(to: .hidden)
    }

    private func transition(to target: IslandPhase) {
        finishAnimation?.cancel()
        transitionID += 1
        let token = transitionID
        let wasVisible = panel.isVisible
        if !wasVisible {
            updateGeometry()
            presentation.setPhase(.hidden, animated: false)
        }
        let previous = presentation.phase
        panel.ignoresMouseEvents = target == .hidden
        panel.setFrame(presentation.geometry.panelFrame(from: previous, to: target), display: true)
        if target != .hidden { panel.orderFrontRegardless() }
        // Give the hosting view a layout at the old size before starting the spring.
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.transitionID else { return }
            self.presentation.setPhase(target, animated: true)
            self.finishAnimation = Task { [weak self] in
                let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 420
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, token == self.transitionID else { return }
                if target == .hidden { self.panel.orderOut(nil) }
                self.panel.setFrame(self.presentation.geometry.panelFrame(from: target, to: target), display: true)
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? returnApplication : front
        var activeWindow: CGRect?
        if let pid = app?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      rect.width > 100, rect.height > 60 else { continue }
                activeWindow = DisplaySelection.appKitRect(quartz: rect, primaryHeight: primaryHeight)
                break
            }
        }
        guard let index = DisplaySelection.index(screens: screens.map(\.frame), window: activeWindow,
            pointer: NSEvent.mouseLocation, usePrimary: UserDefaults.standard.string(forKey: "displayMode") == "primary") else { return nil }
        return screens[index]
    }

    private func updateGeometry() {
        guard let screen = targetScreen() else { return }
        presentation.geometry = NotchGeometry(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    @objc private func screenChanged() {
        transitionID += 1
        finishAnimation?.cancel()
        updateGeometry()
        panel.setFrame(presentation.geometry.panelFrame(from: presentation.phase, to: presentation.phase), display: true)
        if presentation.phase == .hidden { panel.orderOut(nil) }
    }

    private func updateStatus() {
        statusItem.button?.title = model.items.isEmpty ? "" : " \(model.items.count)"
        statusItem.button?.toolTip = model.isPaused ? "Herdr Island · quiet for 30 minutes" : "Herdr Island · \(model.items.count) waiting · ⌃⌥Space"
    }

    private func showMenu() {
        let menu = NSMenu()
        addItem("Open inbox", action: #selector(openInbox), to: menu)
        addItem(model.isPaused ? "Resume popups" : "Quiet for 30 minutes", action: #selector(togglePause), to: menu)
        if model.demo { addItem("Replay demo", action: #selector(replayDemo), to: menu) }
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addItem("Quit Herdr Island", action: #selector(quit), to: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openInbox() {
        if model.expanded && panel.isKeyWindow { model.collapse(); return }
        settingsWindow?.orderOut(nil)
        updateGeometry()
        model.expand()
        focusIsland(resetResponder: true)
        model.focusRequest += 1
    }

    private func focusIsland(resetResponder: Bool) {
        if !panel.isKeyWindow {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { returnApplication = front }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.keyboardActive = true
        model.focusRequest += 1
        if resetResponder { panel.makeFirstResponder(panel.contentView) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        model.keyboardActive = true
        model.focusRequest += 1
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        model.keyboardActive = false
        keyboard.reset()
        model.prefixPending = false
    }

    private func handle(_ command: IslandCommand) {
        switch command {
        case .home: model.showHome(); panel.makeFirstResponder(panel.contentView)
        case .activateSelection: model.openHomeSelection()
        case .highlightRelative(let offset): model.moveHomeSelection(offset)
        case .collapse: model.collapse()
        case .help: model.toggleHelp(); if model.showingHelp { panel.makeFirstResponder(panel.contentView) }
        case .settings: showSettings()
        case .refresh: model.reconnectTerminal()
        case .openAgent: model.openAgent()
        case .dismiss: model.dismiss()
        case .snooze: model.snooze()
        case .toggleQuiet: model.togglePause()
        case .replayDemo: model.replayDemo()
        case .selectRelative(let offset): model.selectRelative(offset)
        case .selectIndex(let index): model.selectIndex(index)
        case .literalPrefix: model.sendLiteralPrefix?()
        case .copySelection, .paste, .selectAll: model.editTerminal?(command)
        case .passThrough, .consume, .prefix, .cancelPrefix: break
        }
    }

    private func keyInput(_ event: NSEvent) -> IslandKey {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let special: [UInt16: String] = [36: "return", 76: "return", 53: "escape", 48: "tab", 49: "space",
            123: "left", 124: "right", 125: "down", 126: "up", 116: "pageup", 121: "pagedown", 115: "home", 119: "end"]
        let prefixKeys: [UInt16: String] = [0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 29: "0", 28: "8", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 43: ",", 44: "/", 45: "n", 46: "m"]
        let physical = keyboard.prefixPending || modifiers.contains(.command) ? prefixKeys[event.keyCode] : nil
        let key = event.keyCode == 11 && modifiers == .control ? "b" : special[event.keyCode] ?? physical ?? event.charactersIgnoringModifiers ?? ""
        return IslandKey(key, modifiers: modifiers, repeating: event.isARepeat)
    }
    @objc private func togglePause() { model.togglePause() }
    @objc private func replayDemo() { model.replayDemo() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        openingSettings = true
        model.collapse()
        openingSettings = false
        // The status-bar-level island must be gone before a normal window receives focus.
        autoCollapse?.cancel(); finishAnimation?.cancel(); transitionID += 1
        presentation.setPhase(.hidden, animated: false)
        panel.orderOut(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Herdr Island Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if let screen = targetScreen(), let window = settingsWindow {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                         y: screen.visibleFrame.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.shortcutInvoked() }
            return noErr
        }, 1, &type, pointer, &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x48455244, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.error = "⌃⌥Space is already in use by another app." }
        if CommandLine.arguments.contains("--debug-input") { print("Global shortcut registration: \(result)"); fflush(stdout) }
    }

    private func shortcutInvoked() {
        guard Date().timeIntervalSince(lastShortcutAt) > 0.2 else { return }
        lastShortcutAt = Date()
        openInbox()
    }

    private func saveSnapshot(path: String) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.collapse()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @State private var path = ""
    @State private var executable = ""
    @AppStorage("terminalBundle") private var terminal = "com.mitchellh.ghostty"
    @AppStorage("notificationSound") private var notificationSound = true
    @AppStorage("displayMode") private var displayMode = "current"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Socket", text: $path).font(.system(size: 11, design: .monospaced))
                TextField("Herdr executable", text: $executable).font(.system(size: 11, design: .monospaced))
                HStack {
                    Text(model.demo ? "Demo" : model.connected ? "Connected" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect") {
                        UserDefaults.standard.set(NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath, forKey: "socketPath")
                        UserDefaults.standard.set(NSString(string: executable.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath, forKey: "herdrExecutable")
                        model.reconnect()
                    }.keyboardShortcut(.return, modifiers: .command)
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.demo)
                }
            }
            Section("Display") {
                Picker("Open on", selection: $displayMode) {
                    Text("Display I’m working on").tag("current")
                    Text("Primary display").tag("primary")
                }
                Picker("External terminal", selection: $terminal) {
                    Text("Ghostty").tag("com.mitchellh.ghostty")
                    Text("iTerm2").tag("com.googlecode.iterm2")
                    Text("Terminal").tag("com.apple.Terminal")
                    Text("WezTerm").tag("com.github.wez.wezterm")
                    Text("kitty").tag("net.kovidgoyal.kitty")
                    Text("Alacritty").tag("org.alacritty")
                }
                Toggle("Notification sound", isOn: $notificationSound)
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                }.disabled(model.demo)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Text("⌘Return connects · Esc closes Settings").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding(5).frame(width: 520, height: 400)
            .onAppear { path = model.socketPath; executable = model.executablePath }
    }
}
