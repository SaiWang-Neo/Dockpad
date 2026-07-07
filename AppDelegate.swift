import AppKit
import SwiftUI
import Combine
import Carbon

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var dockPanel: CustomDockPanel?
    var settingsWindow: NSWindow?
    
    private var globalMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var previousActiveApp: NSRunningApplication?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDisplayMode(AppMonitor.shared.displayMode, animated: false)
        setupStatusItem()
        
        // Wrap CustomDockView in hosting view that accepts first mouse (click-through)
        let hostingView = ClickThroughHostingView(rootView: CustomDockView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        dockPanel = CustomDockPanel(contentView: hostingView)
        
        // Show launchpad by default on startup — orderFrontRegardless never activates the App
        dockPanel?.orderFrontRegardless()
        
        setupMainMenu()
        
        // Notification observers
        NotificationCenter.default.addObserver(self, selector: #selector(hideLaunchpad),
            name: Notification.Name("HideLaunchpad"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged),
            name: Notification.Name("DisplayModeChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutChanged),
            name: Notification.Name("ShortcutChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings),
            name: Notification.Name("ShowPreferences"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged),
            name: Notification.Name("LanguageChanged"), object: nil)
        
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(workspaceDidActivateApp),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        // Install global hotkey event handler once
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let mySelf = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                OSType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                if hotKeyID.signature == OSType(0x4D79446B) { // 'MyDk'
                    if hotKeyID.id == 1 {
                        DispatchQueue.main.async {
                            mySelf.toggleDockPanel()
                        }
                    }
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, ptr, &self.eventHandlerRef)
        
        registerAllGlobalShortcuts()
    }
    
    // applicationDidResignActive is automatically called whenever the user switches spaces or clicks outside,
    // which safely hides the settingsWindow and the Launchpad.
    func applicationDidResignActive(_ notification: Notification) {
        hideLaunchpad()
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // If the system accidentally activates this app in .regular mode,
        // immediately deactivate to prevent any flicker.
        if NSApp.activationPolicy() == .regular {
            DispatchQueue.main.async {
                NSApp.deactivate()
            }
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        DockController.shared.restoreDock()
        registerAllGlobalShortcuts()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DockController.shared.restoreDock()
        if let ref = hotKeyRefToggle { UnregisterEventHotKey(ref) }
    }
    
    // MARK: - Dock Icon Behaviour
    
    /// Called when user clicks the Dock icon while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppMonitor.shared.dockClickBehavior == "MissionControl" {
            launchMissionControl()
        } else {
            toggleDockPanel()
        }
        return false
    }
    
    /// Right-click / ctrl-click context menu on the Dock tile.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return buildStatusBarMenu(isDockMenu: true)
    }
    private func buildStatusBarMenu(isDockMenu: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let lang = AppMonitor.shared.appLanguage
        let isZh = (lang == "zh")
        
        let toggleItem = NSMenuItem(title: localizedString("menu_toggle", lang: lang), action: #selector(toggleDockPanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Mission Control
        let missionControlItem = NSMenuItem(title: isZh ? "调度中心" : "Mission Control", action: #selector(launchMissionControl), keyEquivalent: "")
        missionControlItem.target = self
        menu.addItem(missionControlItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Hide/Show desktop files menu option
        let desktopTitle = AppMonitor.shared.hideDesktopFiles 
            ? localizedString("menu_show_desktop_files", lang: lang) 
            : localizedString("menu_hide_desktop_files", lang: lang)
        let desktopItem = NSMenuItem(title: desktopTitle, action: #selector(toggleDesktopFilesMenu), keyEquivalent: "")
        desktopItem.target = self
        menu.addItem(desktopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: localizedString("menu_preferences", lang: lang), action: #selector(showSettings), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        if !isDockMenu {
            menu.addItem(NSMenuItem.separator())
            
            let quitItem = NSMenuItem(title: localizedString("menu_quit", lang: lang), action: #selector(quitApp), keyEquivalent: "")
            quitItem.target = self
            menu.addItem(quitItem)
        }
        
        return menu
    }
    
    @objc private func toggleDesktopFilesMenu() {
        AppMonitor.shared.hideDesktopFiles.toggle()
        AppMonitor.shared.saveLayoutPreferences()
    }
    
    // MARK: - Display Mode
    
    @objc func displayModeChanged() {
        applyDisplayMode(AppMonitor.shared.displayMode, animated: true)
    }
    
    private func applyDisplayMode(_ mode: String, animated: Bool) {
        updateStatusBarToolTip()
        setupMainMenu()
        
        switch mode {
        case "Dock":
            // Show in macOS Dock; hide menubar icon
            NSApp.setActivationPolicy(.regular)
            statusItem?.isVisible = false
        case "Both":
            // Show in both macOS Dock and status bar
            NSApp.setActivationPolicy(.regular)
            statusItem?.isVisible = true
        default:
            // "MenuBar" — agent app (hidden from Dock), show menubar icon only
            NSApp.setActivationPolicy(.accessory)
            statusItem?.isVisible = true
        }
    }
    
    // MARK: - Global Shortcut
    
    @objc func shortcutChanged() {
        registerAllGlobalShortcuts()
        updateStatusBarToolTip()
    }
    
    @objc func languageChanged() {
        updateStatusBarToolTip()
        setupMainMenu()
    }
    
    private func getShortcutLabel(_ shortcut: String) -> String {
        let parts = shortcut.split(separator: ",")
        if parts.count >= 3 {
            return String(parts[2])
        }
        return shortcut
    }
    
    func updateStatusBarToolTip() {
        guard let button = statusItem?.button else { return }
        let lang = AppMonitor.shared.appLanguage
        if lang == "zh" {
            let label = getShortcutLabel(AppMonitor.shared.launchShortcut)
            button.toolTip = "切换显示启动台 (\(label))"
        } else {
            button.toolTip = ""
        }
    }
    
    // Carbon HotKey references
    private var hotKeyRefToggle: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    
    private func registerAllGlobalShortcuts() {
        // Unregister existing
        if let ref = hotKeyRefToggle { UnregisterEventHotKey(ref); hotKeyRefToggle = nil }
        
        func registerHotkey(shortcut: String, id: UInt32, refPtr: UnsafeMutablePointer<EventHotKeyRef?>) {
            var parts = shortcut.split(separator: ",", maxSplits: 2)
            if parts.count < 3 {
                if shortcut == "Option+Space" {
                    parts = ["49", "2048", "Option+Space"]
                } else {
                    return
                }
            }
            guard let keyCode = UInt32(parts[0]),
                  let modifiers = UInt32(parts[1]) else { return }
            
            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = OSType(0x4D79446B) // 'MyDk'
            hotKeyID.id = id
            
            RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, refPtr)
        }
        
        registerHotkey(shortcut: AppMonitor.shared.launchShortcut, id: 1, refPtr: &hotKeyRefToggle)
    }
    
    @objc func launchMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.open(url)
    }
    

    
    // MARK: - Status Bar & Menu Setup
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let lang = AppMonitor.shared.appLanguage
        let isZh = lang == "zh"
        
        // 1. Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: isZh ? "关于 Dockpad" : "About Dockpad", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: localizedString("menu_preferences", lang: lang), action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: localizedString("menu_quit", lang: lang), action: #selector(quitApp), keyEquivalent: "q"))
        
        // 2. File Menu
        let fileMenu = NSMenu(title: isZh ? "文件" : "File")
        fileMenu.addItem(NSMenuItem(title: isZh ? "偏好设置..." : "Preferences...", action: #selector(showSettings), keyEquivalent: ","))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: isZh ? "显示/隐藏桌面文件" : "Show/Hide Desktop Files", action: #selector(toggleDesktopFilesMenu), keyEquivalent: "d"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: isZh ? "关闭窗口" : "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem(title: isZh ? "文件" : "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        // 3. View Menu
        let viewMenu = NSMenu(title: isZh ? "视图" : "View")
        viewMenu.addItem(NSMenuItem(title: localizedString("menu_toggle", lang: lang), action: #selector(toggleDockPanel), keyEquivalent: "t"))
        viewMenu.addItem(NSMenuItem(title: isZh ? "调度中心" : "Mission Control", action: #selector(launchMissionControl), keyEquivalent: "e"))
        viewMenu.addItem(NSMenuItem(title: isZh ? "刷新/重载Dock栏" : "Refresh Dock", action: #selector(reloadIcons), keyEquivalent: "r"))
        let viewMenuItem = NSMenuItem(title: isZh ? "视图" : "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        
        // 4. Window Menu
        let windowMenu = NSMenu(title: isZh ? "窗口" : "Window")
        windowMenu.addItem(NSMenuItem(title: isZh ? "最小化" : "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: isZh ? "缩放" : "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: isZh ? "前置设置窗口" : "Bring Preferences to Front", action: #selector(showSettings), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem(title: isZh ? "窗口" : "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        // 5. Help Menu
        let helpMenu = NSMenu(title: isZh ? "帮助" : "Help")
        helpMenu.addItem(NSMenuItem(title: isZh ? "关于 Dockpad" : "About Dockpad", action: #selector(showAbout), keyEquivalent: ""))
        let helpMenuItem = NSMenuItem(title: isZh ? "帮助" : "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc func hideLaunchpad() {
        DispatchQueue.main.async {
            self.dockPanel?.orderOut(nil)
            NSApp.deactivate()
            if let prevApp = self.previousActiveApp {
                prevApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.image = NSImage(systemSymbolName: "square.grid.3x3.square", accessibilityDescription: "Launchpad")
        button.image?.isTemplate = true
        
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        // Initial visibility
        let isVisible = (AppMonitor.shared.displayMode != "Dock")
        statusItem?.isVisible = isVisible
        
        updateStatusBarToolTip()
    }
    
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Right-click or Ctrl-click: show menu!
            let menu = buildStatusBarMenu(isDockMenu: false)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            // Left-click: action depending on preferences!
            if AppMonitor.shared.statusBarClickBehavior == "MissionControl" {
                launchMissionControl()
            } else {
                toggleDockPanel()
            }
        }
    }
    
    @objc func showSettings() {
        showSettingsWithTab(0)
    }
    
    @objc func showAbout() {
        showSettingsWithTab(3)
    }
    
    private func showSettingsWithTab(_ tab: Int) {
        AppMonitor.shared.activeSettingsTab = tab
        NotificationCenter.default.post(name: Notification.Name("SettingsTabChanged"), object: tab)
        
        if settingsWindow == nil {
            let hostingView = NSHostingView(rootView: SettingsView())
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置偏好"
            window.minSize = NSSize(width: 700, height: 460)
            // moveToActiveSpace ensures it opens on whichever desktop the user is currently on
            window.collectionBehavior = [.moveToActiveSpace, .participatesInCycle]
            window.titlebarAppearsTransparent = false
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // For the Preferences window we DO want to bring the app forward so the user can interact with it.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc private func workspaceDidActivateApp(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousActiveApp = app
        }
    }
    
    @objc func reloadIcons() {
        AppMonitor.shared.reloadApps()
        dockPanel?.reposition()
    }
    
    @objc func toggleDockPanel() {
        guard let panel = dockPanel else { return }
        if panel.isVisible {
            hideLaunchpad()
        } else {
            // orderFrontRegardless shows the window without activating the App
            // → the currently active app (Safari, Finder, etc.) keeps its focus and menu bar
            panel.reposition()
            panel.orderFrontRegardless()
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
