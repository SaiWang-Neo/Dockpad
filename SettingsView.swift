import SwiftUI
import AppKit

class SettingsViewStore: ObservableObject {
    @Published var activeTab = 0 {
        didSet {
            AppMonitor.shared.activeSettingsTab = activeTab
        }
    }
    @Published var hideSearchText = ""
    @Published var hoveredTab: Int? = nil
    
    // Collections editor state moved to class-based store to avoid struct @State compiler macro bugs
    @Published var selectedFolderId: String? = nil
    @Published var folderNameInput: String = "New Dock"
    @Published var selectedAppIds: Set<String> = []
    @Published var searchAppText: String = ""
    
    init() {
        self.activeTab = AppMonitor.shared.activeSettingsTab
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabChange(_:)), name: Notification.Name("SettingsTabChanged"), object: nil)
    }
    
    @objc private func handleTabChange(_ notification: Notification) {
        if let tab = notification.object as? Int {
            self.activeTab = tab
        }
    }
}

// Inline app icon loader view for preferences lists
private struct AppIconThumb: View {
    let app: DockItem
    var body: some View {
        let icon: NSImage = {
            if !app.path.isEmpty, FileManager.default.fileExists(atPath: app.path) {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSWorkspace.shared.icon(forFileType: "app")
        }()
        return Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)  // Enlarged for better readability
    }
}

// MARK: - Keyboard Shortcut Recorder
// Captures a user key combination (modifier + key) and stores it as "Modifier+Key" string.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: String
    var onChange: (String) -> Void
    
    class Coordinator: NSObject {
        var parent: ShortcutRecorderView
        weak var fieldRef: RecorderField?
        init(_ parent: ShortcutRecorderView) { self.parent = parent }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.coordinator = context.coordinator
        context.coordinator.fieldRef = field
        field.displayText = shortcut
        return field
    }
    
    func updateNSView(_ nsView: RecorderField, context: Context) {
        if !nsView.isRecording {
            let parts = shortcut.split(separator: ",", maxSplits: 2)
            if parts.count >= 3 {
                nsView.displayText = String(parts[2])
            } else {
                nsView.displayText = shortcut
            }
            nsView.needsDisplay = true
        }
    }
}

/// Custom NSControl that enters "recording" mode on click and captures the next key combination.
final class RecorderField: NSControl {
    var coordinator: ShortcutRecorderView.Coordinator?
    var displayText: String = "" { didSet { needsDisplay = true } }
    var isRecording = false
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        // Background
        let bg = isRecording ? NSColor.systemBlue.withAlphaComponent(0.12) : NSColor.controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        
        // Label
        let label = isRecording ? "Press key combination…" : (displayText.isEmpty ? "Click to record" : displayText)
        let color = isRecording ? NSColor.systemBlue : NSColor.labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        let size = label.size(withAttributes: attrs)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        label.draw(at: origin, withAttributes: attrs)
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }
    
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let char = (event.charactersIgnoringModifiers ?? "").lowercased()
        
        // Ignore bare modifier-only presses
        guard !char.isEmpty, !["\u{1b}"].contains(char) else {
            if char == "\u{1b}" { cancelRecording() }
            return
        }
        
        var parts: [String] = []
        var carbonMods: UInt32 = 0
        if mods.contains(.command)  { parts.append("Command"); carbonMods |= 256 } // cmdKey
        if mods.contains(.option)   { parts.append("Option"); carbonMods |= 2048 } // optionKey
        if mods.contains(.control)  { parts.append("Control"); carbonMods |= 4096 } // controlKey
        if mods.contains(.shift)    { parts.append("Shift"); carbonMods |= 512 } // shiftKey
        
        let keyLabel: String
        if event.keyCode == 123 {
            keyLabel = "Left"
        } else if event.keyCode == 124 {
            keyLabel = "Right"
        } else if event.keyCode == 125 {
            keyLabel = "Down"
        } else if event.keyCode == 126 {
            keyLabel = "Up"
        } else {
            switch char {
            case " ": keyLabel = "Space"
            default:  keyLabel = char.uppercased()
            }
        }
        parts.append(keyLabel)
        
        let displayStr = parts.joined(separator: "+")
        let result = "\(event.keyCode),\(carbonMods),\(displayStr)"
        
        displayText = displayStr
        isRecording = false
        needsDisplay = true
        coordinator?.parent.shortcut = result
        coordinator?.parent.onChange(result)
    }
    
    private func cancelRecording() {
        isRecording = false
        needsDisplay = true
    }
    
    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

// ── Web-Style Card Modifier ─────────────────────────────────────────────
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

// ── Shared UI Elements ──────────────────────────────────────────────────
struct SectionHeader: View {
    let title: String
    let subtitle: String?
    
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .default))
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
            }
        }
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let tabIndex: Int
    @ObservedObject var store: SettingsViewStore
    let action: () -> Void
    
    private var isActive: Bool {
        store.activeTab == tabIndex
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: isActive ? .medium : .regular))
                    .foregroundColor(isActive ? .primary : .secondary)
                    .frame(width: 20, height: 20)
                
                Text(title)
                    .font(.system(size: 14, weight: isActive ? .medium : .regular))
                    .foregroundColor(isActive ? .primary : .secondary)
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.primary.opacity(0.08) : (store.hoveredTab == tabIndex ? Color.primary.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .focusable(false)
        .onHover { hover in
            if hover {
                store.hoveredTab = tabIndex
            } else if store.hoveredTab == tabIndex {
                store.hoveredTab = nil
            }
        }
    }
}

// 1. Collections tab view
struct CollectionsSettingsView: View {
    @ObservedObject var appMonitor = AppMonitor.shared
    @ObservedObject var store: SettingsViewStore
    
    private var filteredApps: [DockItem] {
        let allApps = appMonitor.apps.flatMap { item -> [DockItem] in
            item.isFolder ? (item.children ?? []) : [item]
        }
        var unique: [DockItem] = []
        var seen = Set<String>()
        for app in allApps {
            if !seen.contains(app.id) {
                unique.append(app)
                seen.insert(app.id)
            }
        }
        let sorted = unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sorted.filter {
            (!appMonitor.hiddenAppPaths.contains($0.path)) &&
            (store.searchAppText.isEmpty || $0.name.localizedCaseInsensitiveContains(store.searchAppText))
        }
    }
    
    private var parentFolderMap: [String: String] {
        var map: [String: String] = [:]
        for item in appMonitor.apps where item.isFolder {
            for child in item.children ?? [] {
                if let currentId = store.selectedFolderId, item.id == currentId {
                    continue
                }
                map[child.id] = item.name
            }
        }
        return map
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                
                Text("Dock Collections")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)
                
                SettingsCard {
                    SectionHeader("Select Collection", subtitle: "Choose a dock folder to edit, or create a new one.")
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button(action: {
                                store.selectedFolderId = nil
                                store.folderNameInput = "New Dock"
                                store.selectedAppIds.removeAll()
                            }) {
                                Text("New")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(store.selectedFolderId == nil ? Color.primary : Color.primary.opacity(0.05))
                                    .foregroundColor(store.selectedFolderId == nil ? Color(NSColor.windowBackgroundColor) : .primary)
                                    .cornerRadius(20)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            let folders = appMonitor.apps.filter { $0.isFolder }
                            ForEach(folders) { folder in
                                Button(action: {
                                    store.selectedFolderId = folder.id
                                    store.folderNameInput = folder.name
                                    store.selectedAppIds = Set(folder.children?.map { $0.id } ?? [])
                                }) {
                                    Text(folder.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(store.selectedFolderId == folder.id ? Color.primary : Color.primary.opacity(0.05))
                                        .foregroundColor(store.selectedFolderId == folder.id ? Color(NSColor.windowBackgroundColor) : .primary)
                                        .cornerRadius(20)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                SettingsCard {
                    SectionHeader("Edit Collection", subtitle: "Name your dock and select the applications to include.")
                    
                    HStack {
                        Text("Dock Name:")
                            .font(.system(size: 14, weight: .medium))
                        TextField("Enter dock name...", text: $store.folderNameInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 200)
                    }
                    
                    TextField("Search apps to add...", text: $store.searchAppText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.top, 8)
                    
                    VStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            HStack(spacing: 12) {
                                AppIconThumb(app: app)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.system(size: 14, weight: .medium))
                                    
                                    if let folderName = parentFolderMap[app.id] {
                                        Text("In dock: \(folderName) — select to move here")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.orange)
                                    }
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: Binding(
                                    get: { store.selectedAppIds.contains(app.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            store.selectedAppIds.insert(app.id)
                                        } else {
                                            store.selectedAppIds.remove(app.id)
                                        }
                                    }
                                ))
                                .toggleStyle(SwitchToggleStyle(tint: .primary))
                                .controlSize(.small)
                            }
                            .padding(.vertical, 8)
                            
                            if app.id != filteredApps.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .padding(.top, 8)
                    
                    HStack {
                        Button("Save Dock") {
                            saveCollection()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary)
                        .foregroundColor(Color(NSColor.windowBackgroundColor))
                        
                        Spacer()
                        
                        if store.selectedFolderId != nil {
                            Button("Delete Dock") {
                                deleteCollection()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                    }
                    .padding(.top, 16)
                }
                
                SettingsCard {
                    SectionHeader(localizedString("settings_backup_categories_title", lang: appMonitor.appLanguage), subtitle: localizedString("settings_backup_categories_desc", lang: appMonitor.appLanguage))
                    
                    HStack(spacing: 12) {
                        Button(localizedString("btn_backup_categories", lang: appMonitor.appLanguage)) {
                            appMonitor.backupDockCategories()
                        }
                        .buttonStyle(.bordered)
                        
                        Button(localizedString("btn_restore_categories", lang: appMonitor.appLanguage)) {
                            appMonitor.restoreDockCategories()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!appMonitor.hasDockCategoriesBackup())
                        
                        Spacer()
                        
                        Button(localizedString("menu_reload", lang: appMonitor.appLanguage)) {
                            appMonitor.reloadApps()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary)
                        .foregroundColor(Color(NSColor.windowBackgroundColor))
                    }
                    .padding(.top, 8)
                }
                
                Spacer().frame(height: 40)
            }
            .padding(30)
        }
    }
    
    private func saveCollection() {
        guard !store.folderNameInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        var appMap: [String: DockItem] = [:]
        for item in appMonitor.apps {
            if item.isFolder {
                for child in item.children ?? [] {
                    appMap[child.id] = child
                }
            } else {
                appMap[item.id] = item
            }
        }
        
        var folderChildren: [DockItem] = []
        for appId in store.selectedAppIds {
            if let app = appMap[appId] {
                folderChildren.append(app)
            }
        }
        
        var updatedApps: [DockItem] = []
        var appsInOtherFolders = Set<String>()
        
        for item in appMonitor.apps {
            if item.isFolder {
                if let currentId = store.selectedFolderId, item.id == currentId {
                    continue
                }
                
                if let children = item.children {
                    let remaining = children.filter { !store.selectedAppIds.contains($0.id) }
                    if !remaining.isEmpty {
                        var updatedFolder = item
                        updatedFolder.children = remaining
                        updatedApps.append(updatedFolder)
                        for r in remaining {
                            appsInOtherFolders.insert(r.id)
                        }
                    }
                }
            }
        }
        
        if let currentId = store.selectedFolderId {
            let folderToUpdate = DockItem(
                id: currentId,
                name: store.folderNameInput,
                bundleId: "folder.\(store.folderNameInput.lowercased())",
                path: "",
                isFolder: true,
                children: folderChildren
            )
            updatedApps.insert(folderToUpdate, at: 0)
        } else if !folderChildren.isEmpty {
            let newFolder = DockItem(
                id: UUID().uuidString,
                name: store.folderNameInput,
                bundleId: "folder.\(store.folderNameInput.lowercased())",
                path: "",
                isFolder: true,
                children: folderChildren
            )
            updatedApps.insert(newFolder, at: 0)
        }
        
        for (appId, app) in appMap {
            if !store.selectedAppIds.contains(appId) && !appsInOtherFolders.contains(appId) {
                updatedApps.append(app)
            }
        }
        
        appMonitor.apps = updatedApps
        appMonitor.saveLayout()
        appMonitor.reverifyRunningState()
        
        store.selectedFolderId = nil
        store.folderNameInput = "New Dock"
        store.selectedAppIds.removeAll()
    }
    
    private func deleteCollection() {
        guard let folderId = store.selectedFolderId else { return }
        appMonitor.disbandFolder(folderId: folderId)
        store.selectedFolderId = nil
        store.folderNameInput = "New Dock"
        store.selectedAppIds.removeAll()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var appMonitor = AppMonitor.shared
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                
                Text(appMonitor.appLanguage == "zh" ? "通用设置" : "General Settings")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)
                
                // ── Language ───────────────────────────────────────────
                SettingsCard {
                    SectionHeader(localizedString("settings_language", lang: appMonitor.appLanguage), subtitle: localizedString("settings_language_desc", lang: appMonitor.appLanguage))
                    
                    Picker("", selection: Binding(
                        get: { appMonitor.appLanguage },
                        set: {
                            appMonitor.appLanguage = $0
                            appMonitor.saveLayoutPreferences()
                            NotificationCenter.default.post(name: Notification.Name("DisplayModeChanged"), object: nil)
                        }
                    )) {
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                    }
                    .pickerStyle(PopUpButtonPickerStyle())
                    .frame(width: 200)
                }
                
                // ── Display Mode ──────────────────────────────────────
                SettingsCard {
                    SectionHeader(localizedString("settings_display_mode", lang: appMonitor.appLanguage), subtitle: localizedString("settings_display_mode_desc", lang: appMonitor.appLanguage))
                    
                    Picker("", selection: Binding(
                        get: { appMonitor.displayMode },
                        set: { appMonitor.displayMode = $0; appMonitor.saveLayoutPreferences()
                              NotificationCenter.default.post(name: Notification.Name("DisplayModeChanged"), object: nil)
                        }
                    )) {
                        Text(localizedString("settings_show_in_menubar", lang: appMonitor.appLanguage)).tag("MenuBar")
                        Text(localizedString("settings_show_in_dock", lang: appMonitor.appLanguage)).tag("Dock")
                        Text(localizedString("settings_show_in_both", lang: appMonitor.appLanguage)).tag("Both")
                    }
                    .pickerStyle(PopUpButtonPickerStyle())
                    .frame(width: 200)
                }
                
                // ── Launch Shortcut ────────────────────────────────────
                SettingsCard {
                    SectionHeader(localizedString("settings_shortcut", lang: appMonitor.appLanguage), subtitle: localizedString("settings_shortcut_desc", lang: appMonitor.appLanguage))
                    
                    ShortcutRecorderView(
                        shortcut: Binding(
                            get: { appMonitor.launchShortcut },
                            set: { appMonitor.launchShortcut = $0 }
                        ),
                        onChange: { newShortcut in
                            appMonitor.launchShortcut = newShortcut
                            appMonitor.saveLayoutPreferences()
                            NotificationCenter.default.post(name: Notification.Name("ShortcutChanged"), object: nil)
                        }
                    )
                    .frame(width: 220, height: 32)
                }
                
                // ── Click Behaviors ────────────────────────────────────
                SettingsCard {
                    SectionHeader(appMonitor.appLanguage == "zh" ? "点击图标行为" : "Icon Click Behavior", subtitle: appMonitor.appLanguage == "zh" ? "设置左键点击 Dock 栏图标或状态栏图标时的触发行为（右键点击状态栏图标仍会打开快捷菜单）。" : "Configure the action when left-clicking the Dock or status item. Right-clicking the status item always opens the menu.")
                    
                    VStack(spacing: 16) {
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "Dock 栏左键点击：" : "Dock Left-Click:")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 140, alignment: .leading)
                            
                            Picker("", selection: Binding(
                                get: { appMonitor.dockClickBehavior },
                                set: { appMonitor.dockClickBehavior = $0; appMonitor.saveLayoutPreferences() }
                            )) {
                                Text(appMonitor.appLanguage == "zh" ? "打开启动台" : "Open Launchpad").tag("Launchpad")
                                Text(appMonitor.appLanguage == "zh" ? "调度中心" : "Mission Control").tag("MissionControl")
                            }
                            .pickerStyle(PopUpButtonPickerStyle())
                            .frame(width: 180)
                            
                            Spacer()
                        }
                        
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "状态栏左键点击：" : "Status Item Left-Click:")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 140, alignment: .leading)
                            
                            Picker("", selection: Binding(
                                get: { appMonitor.statusBarClickBehavior },
                                set: { appMonitor.statusBarClickBehavior = $0; appMonitor.saveLayoutPreferences() }
                            )) {
                                Text(appMonitor.appLanguage == "zh" ? "打开启动台" : "Open Launchpad").tag("Launchpad")
                                Text(appMonitor.appLanguage == "zh" ? "调度中心" : "Mission Control").tag("MissionControl")
                            }
                            .pickerStyle(PopUpButtonPickerStyle())
                            .frame(width: 180)
                            
                            Spacer()
                        }
                    }
                }
                
                // ── Grid Layout ────────────────────────────────────────
                SettingsCard {
                    SectionHeader(appMonitor.appLanguage == "zh" ? "网格布局" : "Grid Layout", subtitle: "Configure the size and spacing of icons in Launchpad.")
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "图标显示大小：" : "Icon Size:")
                                .font(.system(size: 14))
                                .frame(width: 140, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { appMonitor.appIconSize },
                                    set: { appMonitor.appIconSize = $0; appMonitor.saveLayoutPreferences() }
                                ),
                                in: 32...96,
                                step: 1
                            )
                            .frame(width: 200)
                            Text(String(format: "%.0f pt", appMonitor.appIconSize))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "图标左右间隔：" : "Horizontal Spacing:")
                                .font(.system(size: 14))
                                .frame(width: 140, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { appMonitor.appHorizontalSpacing },
                                    set: { appMonitor.appHorizontalSpacing = $0; appMonitor.saveLayoutPreferences() }
                                ),
                                in: 10...50,
                                step: 1
                            )
                            .frame(width: 200)
                            Text(String(format: "%.0f pt", appMonitor.appHorizontalSpacing))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "图标上下间隔：" : "Vertical Spacing:")
                                .font(.system(size: 14))
                                .frame(width: 140, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { appMonitor.appVerticalSpacing },
                                    set: { appMonitor.appVerticalSpacing = $0; appMonitor.saveLayoutPreferences() }
                                ),
                                in: 10...50,
                                step: 1
                            )
                            .frame(width: 200)
                            Text(String(format: "%.0f pt", appMonitor.appVerticalSpacing))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                
                // ── Font & Presentation ───────────────────────────────────────────────
                SettingsCard {
                    SectionHeader(localizedString("settings_font_style", lang: appMonitor.appLanguage), subtitle: localizedString("settings_font_desc", lang: appMonitor.appLanguage))
                    
                    HStack(spacing: 24) {
                        Picker("", selection: Binding(
                            get: { appMonitor.appLabelFontName },
                            set: { appMonitor.appLabelFontName = $0; appMonitor.saveLayoutPreferences() }
                        )) {
                            Text("System Standard").tag("System")
                            Text("Rounded Modern").tag("Rounded")
                            Text("Monospaced Tech").tag("Monospace")
                            Text("Classic Serif").tag("Serif")
                        }
                        .pickerStyle(PopUpButtonPickerStyle())
                        .frame(width: 160)
                        
                        Toggle(localizedString("settings_font_bold", lang: appMonitor.appLanguage), isOn: Binding(
                            get: { appMonitor.appLabelFontBold },
                            set: { appMonitor.appLabelFontBold = $0; appMonitor.saveLayoutPreferences() }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: .primary))
                        
                        Spacer()
                    }
                }
                
                // ── Visual Theme ──────────────────────────────────
                SettingsCard {
                    SectionHeader("Visual Theme", subtitle: "Customize colors, backgrounds, and visual scale.")
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(localizedString("settings_indicator_color", lang: appMonitor.appLanguage))
                                .font(.system(size: 14))
                                .frame(width: 160, alignment: .leading)
                            
                            Picker("", selection: Binding(
                                get: { appMonitor.runningIndicatorColor },
                                set: { appMonitor.runningIndicatorColor = $0; appMonitor.saveLayoutPreferences() }
                            )) {
                                Text("Active Blue").tag("Blue")
                                Text("Signal Green").tag("Green")
                                Text("Alert Red").tag("Red")
                                Text("Orange Amber").tag("Orange")
                                Text("Monochrome Dark").tag("Dark")
                            }
                            .pickerStyle(PopUpButtonPickerStyle())
                            .frame(width: 160)
                            Spacer()
                        }
                        
                        HStack {
                            Text("Backdrop Style:")
                                .font(.system(size: 14))
                                .frame(width: 160, alignment: .leading)
                            
                            Picker("", selection: Binding(
                                get: { appMonitor.launchpadBlurStyle },
                                set: { appMonitor.launchpadBlurStyle = $0; appMonitor.saveLayoutPreferences() }
                            )) {
                                Text("Dark (暗色)").tag("Dark")
                                Text("Light (亮色)").tag("Light")
                            }
                            .pickerStyle(PopUpButtonPickerStyle())
                            .frame(width: 160)
                            Spacer()
                        }
                        
                        HStack {
                            Text("Card Box Opacity:")
                                .font(.system(size: 14))
                                .frame(width: 160, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { appMonitor.launchpadOpacity },
                                    set: { appMonitor.launchpadOpacity = $0; appMonitor.saveLayoutPreferences() }
                                ),
                                in: 0.0...1.0
                            )
                            .frame(width: 200)
                            Text(String(format: "%.0f%%", appMonitor.launchpadOpacity * 100))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        HStack {
                            Text(appMonitor.appLanguage == "zh" ? "显示比例：" : "Content Scale:")
                                .font(.system(size: 14))
                                .frame(width: 160, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { appMonitor.launchpadContentScale },
                                    set: { appMonitor.launchpadContentScale = $0; appMonitor.saveLayoutPreferences() }
                                ),
                                in: 0.5...0.9,
                                step: 0.05
                            )
                            .frame(width: 200)
                            Text(String(format: "%.0f%%", appMonitor.launchpadContentScale * 100))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        Toggle(localizedString("settings_hide_desktop_files", lang: appMonitor.appLanguage), isOn: Binding(
                            get: { appMonitor.hideDesktopFiles },
                            set: { appMonitor.hideDesktopFiles = $0; appMonitor.saveLayoutPreferences() }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: .primary))
                    }
                }
                
                // ── Launchpad Wallpaper ───────────────────────────────
                SettingsCard {
                    SectionHeader(localizedString("settings_wallpaper", lang: appMonitor.appLanguage), subtitle: localizedString("settings_wallpaper_desc", lang: appMonitor.appLanguage))
                    
                    Toggle(localizedString("settings_wallpaper_enable", lang: appMonitor.appLanguage), isOn: Binding(
                        get: { appMonitor.useCustomWallpaper },
                        set: { appMonitor.useCustomWallpaper = $0; appMonitor.saveLayoutPreferences() }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: .primary))
                    
                    HStack(spacing: 12) {
                        Button(localizedString("settings_wallpaper_choose", lang: appMonitor.appLanguage)) {
                            let openPanel = NSOpenPanel()
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = false
                            openPanel.canChooseFiles = true
                            openPanel.allowedContentTypes = [.image]
                            if openPanel.runModal() == .OK, let url = openPanel.url {
                                appMonitor.customWallpaperPath = url.path
                                appMonitor.useCustomWallpaper = true
                                appMonitor.saveLayoutPreferences()
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        if !appMonitor.customWallpaperPath.isEmpty {
                            let filename = URL(fileURLWithPath: appMonitor.customWallpaperPath).lastPathComponent
                            Text(filename)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .help(appMonitor.customWallpaperPath)
                        }
                    }
                    .padding(.top, 4)
                    
                    if appMonitor.useCustomWallpaper,
                       !appMonitor.customWallpaperPath.isEmpty,
                       let nsImg = NSImage(contentsOfFile: appMonitor.customWallpaperPath) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 64)
                            .cornerRadius(8)
                            .padding(.top, 8)
                    }
                }
                
                // ── Reset ──────────────────────────────────────────────
                SettingsCard {
                    SectionHeader("Reset Layout", subtitle: "Clears all Dock folders, custom sorting, and visibility settings.")
                    
                    Button(appMonitor.appLanguage == "zh" ? "重置布局为系统默认" : "Reset Layout to Native Default") {
                        appMonitor.resetLayoutToDefault()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
                
                Spacer().frame(height: 40)
            }
            .padding(30)
        }
    }
}

struct ShowHideSettingsView: View {
    @ObservedObject var appMonitor = AppMonitor.shared
    @ObservedObject var store: SettingsViewStore
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                
                Text("Show / Hide Apps")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)
                
                SettingsCard {
                    SectionHeader("Manage Visibility", subtitle: "Hide specific applications from your Launchpad.")
                    
                    HStack(spacing: 12) {
                        TextField("Search apps to show/hide...", text: $store.hideSearchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button(action: {
                            appMonitor.reloadApps()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text(appMonitor.appLanguage == "zh" ? "更新加载" : "Reload")
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button(appMonitor.appLanguage == "zh" ? "全部显示" : "Show All") {
                            appMonitor.showAllApps()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 8)
                    
                    let allApps = appMonitor.apps.flatMap { item -> [DockItem] in
                        item.isFolder ? (item.children ?? []) : [item]
                    }
                    let sorted = allApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    let filtered = sorted.filter {
                        store.hideSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(store.hideSearchText)
                    }
                    
                    VStack(spacing: 0) {
                        ForEach(filtered) { app in
                            HStack(spacing: 12) {
                                AppIconThumb(app: app)
                                Text(app.name)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { !appMonitor.hiddenAppPaths.contains(app.path) },
                                    set: { isVisible in
                                        appMonitor.toggleAppVisibility(path: app.path, isVisible: isVisible)
                                    }
                                ))
                                .toggleStyle(SwitchToggleStyle(tint: .primary))
                                .controlSize(.small)
                            }
                            .padding(.vertical, 8)
                            
                            if app.id != filtered.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                
                Spacer().frame(height: 40)
            }
            .padding(30)
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 64))
                .foregroundColor(.primary)
            
            VStack(spacing: 8) {
                Text("Dockpad")
                    .font(.system(size: 28, weight: .bold))
                
                Text("Version 0.1.2")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            Text("Frosted-glass modular Launchpad supporting custom typeface styles, active indicator shapes, resizable preferences sidebars, and collections folders management.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
                .lineSpacing(6)
            
            SettingsCard {
                VStack(spacing: 6) {
                    Text("Author: Neo")
                        .font(.system(size: 14, weight: .medium))
                    
                    Text("Contact: wsaing@icloud.com")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 300)
            
            Text("Created in collaboration with Antigravity AI.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.top, 16)
            
            Spacer()
        }
        .padding(40)
    }
}

struct SettingsView: View {
    @ObservedObject var appMonitor = AppMonitor.shared
    @StateObject private var store = SettingsViewStore()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar Navigation
            VStack(alignment: .leading, spacing: 8) {
                Text(appMonitor.appLanguage == "zh" ? "偏好设置" : "Settings")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 30)
                    .padding(.bottom, 16)
                
                SidebarButton(title: localizedString("tab_general", lang: appMonitor.appLanguage), icon: "gearshape", tabIndex: 0, store: store) {
                    store.activeTab = 0
                }
                .padding(.horizontal, 12)
                
                SidebarButton(title: localizedString("tab_showhide", lang: appMonitor.appLanguage), icon: "eye.slash", tabIndex: 1, store: store) {
                    store.activeTab = 1
                }
                .padding(.horizontal, 12)
                
                SidebarButton(title: localizedString("tab_collections", lang: appMonitor.appLanguage), icon: "folder", tabIndex: 2, store: store) {
                    store.activeTab = 2
                }
                .padding(.horizontal, 12)
                
                SidebarButton(title: localizedString("tab_about", lang: appMonitor.appLanguage), icon: "info.circle", tabIndex: 3, store: store) {
                    store.activeTab = 3
                }
                .padding(.horizontal, 12)
                
                Spacer()
            }
            .frame(width: 260)
            .background(VisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)) // Web-like translucent sidebar
            
            Divider()
                .opacity(0.5)
            
            // Right Detail View
            ZStack {
                Color(NSColor.windowBackgroundColor)
                    .opacity(0.5) // Lighten background
                
                if store.activeTab == 0 {
                    GeneralSettingsView()
                } else if store.activeTab == 1 {
                    ShowHideSettingsView(store: store)
                } else if store.activeTab == 2 {
                    CollectionsSettingsView(store: store)
                } else {
                    AboutSettingsView()
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // .background handled by ZStack
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        // Enable standard web-like clean appearance
        .preferredColorScheme(.none)
    }
}
