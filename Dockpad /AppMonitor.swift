import AppKit
import Combine
import ApplicationServices

enum SelectionDirection {
    case left, right, up, down
}

class AppMonitor: ObservableObject {
    static let shared = AppMonitor()
    
    private var isInitializing = true
    
    @Published var runningBundleIds: Set<String> = []
    @Published var apps: [DockItem] = []
    @Published var hoveredAppId: String? = nil
    @Published var draggedItem: DockItem? = nil {
        didSet {
            if draggedItem != nil {
                isOverTarget = false
                startMouseTracking()
            } else {
                stopMouseTracking()
                isOverTarget = false
            }
        }
    }
    @Published var dragMouseScreenLocation: CGPoint = .zero
    @Published var isOverTarget: Bool = false
    private var mouseTrackingTimer: Timer? = nil
    
    private func startMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self.dragMouseScreenLocation = loc
            }
        }
    }
    
    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }
    @Published var hoveredSpacerIndex: Int? = nil
    @Published var activeFolderPopoverId: String? = nil
    
    // Preferences Configuration (Visibility and Drag Actions)
    @Published var hiddenAppPaths: Set<String> = []
    @Published var dragBehaviorReorder: Bool = true
    @Published var appLabelFontName: String = "System"
    @Published var appLabelFontBold: Bool = true
    @Published var runningIndicatorColor: String = "Blue"
    @Published var runningIndicatorStyle: String = "Dot"
    @Published var appSortOrder: String = "None"   // "None", "Name", "AddTime"
    @Published var displayMode: String = "MenuBar" // "MenuBar" or "Dock"
    @Published var dockClickBehavior: String = "Launchpad" // "Launchpad" or "MissionControl"
    @Published var statusBarClickBehavior: String = "Launchpad" // "Launchpad" or "MissionControl"
    @Published var activeSettingsTab: Int = 0 // Tab index for settings window
    @Published var launchShortcut: String = "49,2048,Option+Space" // hotkey string label
    @Published var appIconSize: Double = 70.0 // 32.0 to 96.0
    @Published var appHorizontalSpacing: Double = 30.0 // 10.0 to 50.0
    @Published var appVerticalSpacing: Double = 30.0 // 10.0 to 50.0
    @Published var hideDesktopFiles: Bool = false {
        didSet {
            if !isInitializing {
                applyDesktopFilesVisibility()
            }
        }
    }

    @Published var launchpadBlurStyle: String = "Dark" // "Dark", "Light"
    @Published var launchpadOpacity: Double = 0.0 // 0.0 (frosted glass) to 1.0 (opaque solid color)
    @Published var appLanguage: String = "en" { // "en" (English) or "zh" (Chinese)
        didSet {
            NotificationCenter.default.post(name: Notification.Name("LanguageChanged"), object: nil)
        }
    }
    @Published var useCustomWallpaper: Bool = false
    @Published var customWallpaperPath: String = ""
    @Published var launchpadContentScale: Double = 0.70 // 0.5 to 0.9. Default 70%
    
    var appsPerRow: Int {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let preferredWidth = screenWidth * CGFloat(launchpadContentScale)
        let spacing = CGFloat(appHorizontalSpacing)
        let size = CGFloat(appIconSize)
        let count = Int((preferredWidth + spacing) / (size + spacing))
        return max(1, count)
    }

    // Auto-calculated icon size based on content scale and apps per row
    // Icon size property returns double representation directly
    var calculatedIconSize: CGFloat {
        return CGFloat(appIconSize)
    }

    // Folder Creation Selection Mode
    @Published var isFolderCreationMode: Bool = false
    @Published var selectedAppIdsForFolder: Set<String> = []
    
    // Folder Disband Confirmation state
    @Published var folderIdToDisband: String? = nil
    
    // Keyboard navigation and filtering
    @Published var searchText: String = "" {
        didSet {
            DispatchQueue.main.async {
                self.selectedAppId = self.filteredApps.first?.id
            }
        }
    }
    @Published var selectedAppId: String? = nil
    
    private var cancellables = Set<AnyCancellable>()
    private let layoutKey = "mydock.customLayout"
    
    // Create new folder from selected applications
    func createFolderFromSelected(name: String) {
        guard !selectedAppIdsForFolder.isEmpty else { return }
        
        var selectedApps: [DockItem] = []
        
        // Gather selected apps from loose apps and existing folders
        for id in selectedAppIdsForFolder {
            if let idx = apps.firstIndex(where: { $0.id == id && !$0.isFolder }) {
                selectedApps.append(apps[idx])
            } else {
                for folder in apps where folder.isFolder {
                    if let children = folder.children,
                       let child = children.first(where: { $0.id == id }) {
                        selectedApps.append(child)
                    }
                }
            }
        }
        
        // Remove selected apps from their old positions
        for id in selectedAppIdsForFolder {
            if let idx = apps.firstIndex(where: { $0.id == id && !$0.isFolder }) {
                apps.remove(at: idx)
            } else {
                for fIdx in 0..<apps.count {
                    if apps[fIdx].isFolder, var children = apps[fIdx].children {
                        if let cIdx = children.firstIndex(where: { $0.id == id }) {
                            children.remove(at: cIdx)
                            apps[fIdx].children = children
                            
                            if children.isEmpty {
                                apps.remove(at: fIdx)
                            } else if children.count == 1 {
                                apps[fIdx] = children[0]
                            }
                            break
                        }
                    }
                }
            }
        }
        
        // Create folder item
        let folderId = UUID().uuidString
        let newFolder = DockItem(
            id: folderId,
            name: name,
            bundleId: "",
            path: "",
            isRunning: false,
            isFolder: true,
            children: selectedApps
        )
        
        apps.insert(newFolder, at: 0)
        selectedAppIdsForFolder.removeAll()
        isFolderCreationMode = false
        
        saveLayout()
        reverifyRunningState()
    }
    
    // Disband folder back into loose apps
    func disbandFolder(folderId: String) {
        guard let idx = apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) else { return }
        let folder = apps[idx]
        if let children = folder.children {
            apps.remove(at: idx)
            for child in children {
                apps.insert(child, at: idx)
            }
        }
        saveLayout()
        reverifyRunningState()
    }
    
    // Computed property: Groups folders at the top, and un-grouped loose apps at the bottom
    var filteredApps: [DockItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter out hidden apps and map folders to only contain visible children
        let visible = apps.compactMap { item -> DockItem? in
            if item.isFolder {
                if let children = item.children {
                    let visibleChildren = children.filter { !hiddenAppPaths.contains($0.path) }
                    if !visibleChildren.isEmpty {
                        var updated = item
                        updated.children = visibleChildren
                        return updated
                    }
                }
                return nil
            } else {
                return hiddenAppPaths.contains(item.path) ? nil : item
            }
        }
        
        var folders = visible.filter { $0.isFolder }
        var looseApps = visible.filter { !$0.isFolder }
        
        // Filter by search query if present
        if !query.isEmpty {
            folders = folders.compactMap { item -> DockItem? in
                if let children = item.children {
                    let matches = children.filter { $0.name.localizedCaseInsensitiveContains(query) }
                    if !matches.isEmpty {
                        var folderCopy = item
                        folderCopy.children = matches
                        return folderCopy
                    }
                }
                return nil
            }
            looseApps = looseApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        
        // Apply sort order to loose apps
        switch appSortOrder {
        case "Name":
            looseApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // folders.sort removed so folder card positions are never altered by app sorting
        case "AddTime":
            // AddTime = reverse of current saved order (newest inserted first via append)
            // We keep the current array order as insertion order; no extra sort needed unless reversed
            break
        default:
            break // "None" – preserve user drag order
        }
        
        // Display Folders first (at the top), and loose Apps second (at the bottom)
        return folders + looseApps
    }
    
    func moveAppToTopLevel(itemId: String) {
        // Helper to locate an item: returns (folderIdx, itemIdx). If top-level, folderIdx is nil.
        func locate(itemId: String) -> (folderIdx: Int?, itemIdx: Int)? {
            if let idx = apps.firstIndex(where: { $0.id == itemId }) {
                return (nil, idx)
            }
            for fIdx in 0..<apps.count {
                if apps[fIdx].isFolder, let children = apps[fIdx].children {
                    if let cIdx = children.firstIndex(where: { $0.id == itemId }) {
                        return (fIdx, cIdx)
                    }
                }
            }
            return nil
        }
        
        guard let source = locate(itemId: itemId) else { return }
        // If it's already top-level, do nothing
        guard source.folderIdx != nil else { return }
        
        DispatchQueue.main.async {
            // Extract from folder
            if let sfIdx = source.folderIdx {
                guard var children = self.apps[sfIdx].children else { return }
                let draggedItem = children.remove(at: source.itemIdx)
                self.apps[sfIdx].children = children
                
                // Add to top-level list
                self.apps.append(draggedItem)
            }
            
            // Clean up empty/single-item folders
            for fIdx in (0..<self.apps.count).reversed() {
                if self.apps[fIdx].isFolder, let children = self.apps[fIdx].children {
                    if children.isEmpty {
                        self.apps.remove(at: fIdx)
                    } else if children.count == 1 {
                        self.apps[fIdx] = children[0]
                    }
                }
            }
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func moveAppToFolderEnd(appId: String, folderId: String) {
        guard appId != folderId else { return }
        
        func locate(itemId: String) -> (folderIdx: Int?, itemIdx: Int)? {
            if let idx = apps.firstIndex(where: { $0.id == itemId }) {
                return (nil, idx)
            }
            for fIdx in 0..<apps.count {
                if apps[fIdx].isFolder, let children = apps[fIdx].children {
                    if let cIdx = children.firstIndex(where: { $0.id == itemId }) {
                        return (fIdx, cIdx)
                    }
                }
            }
            return nil
        }
        
        guard let source = locate(itemId: appId) else { return }
        guard let destIdx = apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) else { return }
        
        // If already at the end of this folder, do nothing
        if let sfIdx = source.folderIdx, sfIdx == destIdx,
           let children = apps[sfIdx].children, source.itemIdx == children.count - 1 {
            return
        }
        
        DispatchQueue.main.async {
            // 1. Extract the app
            let appItem: DockItem
            if let sfIdx = source.folderIdx {
                guard var children = self.apps[sfIdx].children else { return }
                appItem = children.remove(at: source.itemIdx)
                self.apps[sfIdx].children = children
            } else {
                appItem = self.apps.remove(at: source.itemIdx)
            }
            
            // Re-locate target folder after extraction
            if let updatedDestIdx = self.apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) {
                var folder = self.apps[updatedDestIdx]
                var children = folder.children ?? []
                children.append(appItem)
                folder.children = children
                self.apps[updatedDestIdx] = folder
            }
            
            // Clean up empty/single-item folders
            for fIdx in (0..<self.apps.count).reversed() {
                if self.apps[fIdx].isFolder, let children = self.apps[fIdx].children {
                    if children.isEmpty {
                        self.apps.remove(at: fIdx)
                    } else if children.count == 1 {
                        self.apps[fIdx] = children[0]
                    }
                }
            }
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    private init() {
        loadLayoutPreferences()
        isInitializing = false
        updateRunningApplications()
        setupNotifications()
        loadLayout()
    }
    
    func loadLayout() {
        let scanned = DockController.shared.readNativeDockApps()
        
        guard let data = UserDefaults.standard.data(forKey: layoutKey) else {
            DispatchQueue.main.async {
                self.apps = scanned
                self.saveLayout()
                self.reverifyRunningState()
            }
            return
        }
        
        do {
            var saved = try JSONDecoder().decode([DockItem].self, from: data)
            
            var savedPaths = Set<String>()
            func collectPaths(items: [DockItem]) {
                for item in items {
                    if item.isFolder {
                        if let children = item.children {
                            collectPaths(items: children)
                        }
                    } else {
                        savedPaths.insert(item.path)
                    }
                }
            }
            collectPaths(items: saved)
            
            func filterExisting(items: [DockItem]) -> [DockItem] {
                var cleaned: [DockItem] = []
                for var item in items {
                    if item.isFolder {
                        if let children = item.children {
                            let filteredChildren = filterExisting(items: children)
                            if !filteredChildren.isEmpty {
                                item.children = filteredChildren
                                cleaned.append(item)
                            }
                        }
                    } else {
                        if FileManager.default.fileExists(atPath: item.path) {
                            cleaned.append(item)
                        }
                    }
                }
                return cleaned
            }
            saved = filterExisting(items: saved)
            
            var newApps: [DockItem] = []
            for app in scanned {
                if !savedPaths.contains(app.path) {
                    newApps.append(app)
                }
            }
            
            saved.append(contentsOf: newApps)
            
            DispatchQueue.main.async {
                self.apps = saved
                self.selectedAppId = self.filteredApps.first?.id
                self.saveLayout()
                self.reverifyRunningState()
            }
        } catch {
            print("AppMonitor: Sync layout fallback: \(error)")
            DispatchQueue.main.async {
                self.apps = scanned
                self.saveLayout()
                self.reverifyRunningState()
            }
        }
    }
    
    func saveLayout() {
        do {
            let data = try JSONEncoder().encode(apps)
            UserDefaults.standard.set(data, forKey: layoutKey)
        } catch {
            print("AppMonitor: Failed to encode layout: \(error)")
        }
    }
    
    func reloadApps() {
        let scanned = DockController.shared.readNativeDockApps()
        DispatchQueue.main.async {
            // 1. Gather all existing paths of apps currently in layout
            var existingPaths = Set<String>()
            for item in self.apps {
                if item.isFolder {
                    if let children = item.children {
                        for child in children {
                            existingPaths.insert(child.path)
                        }
                    }
                } else {
                    existingPaths.insert(item.path)
                }
            }
            
            // 2. Identify new apps
            var newItems: [DockItem] = []
            for item in scanned {
                if !existingPaths.contains(item.path) {
                    newItems.append(item)
                }
            }
            
            // 3. Remove apps that no longer exist on disk
            let fileManager = FileManager.default
            var updatedApps = self.apps.compactMap { item -> DockItem? in
                if item.isFolder {
                    var folder = item
                    if let children = folder.children {
                        folder.children = children.filter { fileManager.fileExists(atPath: $0.path) }
                    }
                    return folder
                } else {
                    return fileManager.fileExists(atPath: item.path) ? item : nil
                }
            }
            
            // 4. Append new apps to the end
            updatedApps.append(contentsOf: newItems)
            
            self.apps = updatedApps
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func reverifyRunningState() {
        let running = runningBundleIds
        for i in 0..<apps.count {
            if apps[i].isFolder {
                if var children = apps[i].children {
                    for j in 0..<children.count {
                        children[j].isRunning = running.contains(children[j].bundleId)
                    }
                    apps[i].children = children
                }
            } else {
                apps[i].isRunning = running.contains(apps[i].bundleId)
            }
        }
    }
    
    func resetLayoutToDefault() {
        let loadedApps = DockController.shared.readNativeDockApps()
        DispatchQueue.main.async {
            self.apps = loadedApps
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func moveApp(draggedId: String, targetId: String) {
        guard draggedId != targetId else { return }
        
        // Helper to locate an item: returns (folderIdx, itemIdx). If top-level, folderIdx is nil.
        func locate(itemId: String) -> (folderIdx: Int?, itemIdx: Int)? {
            if let idx = apps.firstIndex(where: { $0.id == itemId }) {
                return (nil, idx)
            }
            for fIdx in 0..<apps.count {
                if apps[fIdx].isFolder, let children = apps[fIdx].children {
                    if let cIdx = children.firstIndex(where: { $0.id == itemId }) {
                        return (fIdx, cIdx)
                    }
                }
            }
            return nil
        }
        
        guard let source = locate(itemId: draggedId),
              let _ = locate(itemId: targetId) else {
            return
        }
        
        DispatchQueue.main.async {
            // 1. Extract the dragged item
            let draggedItem: DockItem
            if let sfIdx = source.folderIdx {
                guard var children = self.apps[sfIdx].children else { return }
                draggedItem = children.remove(at: source.itemIdx)
                self.apps[sfIdx].children = children
            } else {
                draggedItem = self.apps.remove(at: source.itemIdx)
            }
            
            // 2. Adjust target index after extraction
            guard let updatedDest = locate(itemId: targetId) else {
                self.apps.append(draggedItem)
                self.saveLayout()
                self.reverifyRunningState()
                return
            }
            
            // 3. Insert into target location
            if let dfIdx = updatedDest.folderIdx {
                guard var children = self.apps[dfIdx].children else { return }
                children.insert(draggedItem, at: updatedDest.itemIdx)
                self.apps[dfIdx].children = children
            } else {
                self.apps.insert(draggedItem, at: updatedDest.itemIdx)
            }
            
            // 4. Clean up empty/single-item folders
            for fIdx in (0..<self.apps.count).reversed() {
                if self.apps[fIdx].isFolder, let children = self.apps[fIdx].children {
                    if children.isEmpty {
                        self.apps.remove(at: fIdx)
                    } else if children.count == 1 {
                        self.apps[fIdx] = children[0]
                    }
                }
            }
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    // Add app directly into a folder container
    func addAppToFolder(appId: String, folderId: String) {
        guard appId != folderId else { return }
        
        func locate(itemId: String) -> (folderIdx: Int?, itemIdx: Int)? {
            if let idx = apps.firstIndex(where: { $0.id == itemId }) {
                return (nil, idx)
            }
            for fIdx in 0..<apps.count {
                if apps[fIdx].isFolder, let children = apps[fIdx].children {
                    if let cIdx = children.firstIndex(where: { $0.id == itemId }) {
                        return (fIdx, cIdx)
                    }
                }
            }
            return nil
        }
        
        guard let source = locate(itemId: appId),
              let _ = apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) else {
            return
        }
        
        DispatchQueue.main.async {
            // 1. Extract the app
            let appItem: DockItem
            if let sfIdx = source.folderIdx {
                guard var children = self.apps[sfIdx].children else { return }
                appItem = children.remove(at: source.itemIdx)
                self.apps[sfIdx].children = children
            } else {
                appItem = self.apps.remove(at: source.itemIdx)
            }
            
            // 2. Add to destination folder children
            if let updatedDestIdx = self.apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) {
                var folder = self.apps[updatedDestIdx]
                var children = folder.children ?? []
                if !children.contains(where: { $0.id == appItem.id }) {
                    children.append(appItem)
                }
                folder.children = children
                self.apps[updatedDestIdx] = folder
            }
            
            // 3. Clean up empty/single-item folders
            for fIdx in (0..<self.apps.count).reversed() {
                if self.apps[fIdx].isFolder, let children = self.apps[fIdx].children {
                    if children.isEmpty {
                        self.apps.remove(at: fIdx)
                    } else if children.count == 1 {
                        self.apps[fIdx] = children[0]
                    }
                }
            }
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func groupItems(draggedId: String, targetId: String) {
        guard draggedId != targetId else { return }
        
        var draggedItem: DockItem? = nil
        var sourceFolderIndex: Int? = nil
        
        if let idx = apps.firstIndex(where: { $0.id == draggedId }) {
            draggedItem = apps.remove(at: idx)
        } else {
            for fIdx in 0..<apps.count {
                if apps[fIdx].isFolder, var children = apps[fIdx].children {
                    if let cIdx = children.firstIndex(where: { $0.id == draggedId }) {
                        draggedItem = children.remove(at: cIdx)
                        apps[fIdx].children = children
                        sourceFolderIndex = fIdx
                        break
                    }
                }
            }
        }
        
        guard let item = draggedItem else { return }
        
        if let fIdx = sourceFolderIndex {
            let folder = apps[fIdx]
            if let children = folder.children {
                if children.isEmpty {
                    apps.remove(at: fIdx)
                } else if children.count == 1 {
                    apps[fIdx] = children[0]
                }
            }
        }
        
        guard let currentTargetIndex = self.apps.firstIndex(where: { $0.id == targetId }) else {
            self.apps.append(item)
            self.saveLayout()
            return
        }
        
        var targetItem = self.apps[currentTargetIndex]
        
        DispatchQueue.main.async {
            if targetItem.isFolder {
                var children = targetItem.children ?? []
                if !children.contains(where: { $0.id == item.id }) {
                    children.append(item)
                }
                targetItem.children = children
                self.apps[currentTargetIndex] = targetItem
            } else {
                let folderId = UUID().uuidString
                let folderName = "Folder"
                let newFolder = DockItem(
                    id: folderId,
                    name: folderName,
                    bundleId: "",
                    path: "",
                    isRunning: false,
                    isFolder: true,
                    children: [targetItem, item]
                )
                self.apps[currentTargetIndex] = newFolder
            }
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func removeItemFromFolder(itemId: String, folderId: String) {
        guard let folderIndex = apps.firstIndex(where: { $0.id == folderId }) else { return }
        var folder = apps[folderIndex]
        guard var children = folder.children,
              let childIndex = children.firstIndex(where: { $0.id == itemId }) else {
            return
        }
        
        DispatchQueue.main.async {
            let extractedItem = children.remove(at: childIndex)
            folder.children = children
            
            if children.isEmpty {
                self.apps.remove(at: folderIndex)
            } else if children.count == 1 {
                self.apps[folderIndex] = children[0]
            } else {
                self.apps[folderIndex] = folder
            }
            
            self.apps.insert(extractedItem, at: folderIndex + 1)
            
            self.saveLayout()
            self.reverifyRunningState()
        }
    }
    
    func renameFolder(folderId: String, newName: String) {
        guard let idx = apps.firstIndex(where: { $0.id == folderId }) else { return }
        DispatchQueue.main.async {
            self.apps[idx].name = newName
            self.saveLayout()
        }
    }
    
    func updateRunningApplications() {
        let runningApps = NSWorkspace.shared.runningApplications
        let regularApps = runningApps.filter { $0.activationPolicy == .regular }
        let bundleIds = regularApps.compactMap { $0.bundleIdentifier }
        
        DispatchQueue.main.async {
            self.runningBundleIds = Set(bundleIds)
            self.reverifyRunningState()
        }
    }
    
    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.activationPolicy == .regular,
                   let bundleId = app.bundleIdentifier {
                    DispatchQueue.main.async {
                        self?.runningBundleIds.insert(bundleId)
                        self?.reverifyRunningState()
                    }
                }
            }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bundleId = app.bundleIdentifier {
                    self?.reverifyAppStillRunning(bundleId: bundleId)
                }
            }
            .store(in: &cancellables)
    }
    
    private func reverifyAppStillRunning(bundleId: String) {
        DispatchQueue.global().async {
            let runningApps = NSWorkspace.shared.runningApplications
            let stillRunning = runningApps.contains { $0.bundleIdentifier == bundleId && $0.activationPolicy == .regular }
            
            DispatchQueue.main.async {
                if !stillRunning {
                    self.runningBundleIds.remove(bundleId)
                    self.reverifyRunningState()
                }
            }
        }
    }
    
    func launchApp(bundleId: String, path: String) {
        DispatchQueue.main.async {
            self.activeFolderPopoverId = nil
            NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
        }
        
        if bundleId.isEmpty {
            if !path.isEmpty, let url = URL(string: "file://\(path)") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        print("AppMonitor: Direct launch fallback failed for \(path): \(error)")
                    }
                }
            }
            return
        }
        
        let success = NSWorkspace.shared.launchApplication(
            withBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifier: nil
        )
        
        if success {
            print("AppMonitor: Successfully activated/launched \(bundleId)")
        } else {
            if !path.isEmpty, let url = URL(string: "file://\(path)") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        print("AppMonitor: Direct launch fallback failed for \(path): \(error)")
                    }
                }
            }
        }
    }
    
    func quitApp(bundleId: String) {
        guard !bundleId.isEmpty else { return }
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        for app in runningApps {
            app.terminate()
        }
    }
    
    func launchSelectedApp() {
        guard let selectedId = selectedAppId else { return }
        for item in apps {
            if item.id == selectedId {
                if item.isFolder {
                    DispatchQueue.main.async {
                        if self.activeFolderPopoverId == item.id {
                            self.activeFolderPopoverId = nil
                        } else {
                            self.activeFolderPopoverId = item.id
                        }
                    }
                } else {
                    launchApp(bundleId: item.bundleId, path: item.path)
                }
                return
            }
            if item.isFolder, let children = childrenForFolder(item.id) {
                if let child = children.first(where: { $0.id == selectedId }) {
                    launchApp(bundleId: child.bundleId, path: child.path)
                    return
                }
            }
        }
    }
    
    func moveSelection(direction: SelectionDirection) {
        moveSelection(direction: direction, columnsCount: appsPerRow)
    }

    private func moveSelection(direction: SelectionDirection, columnsCount: Int) {
        let currentList = filteredApps
        guard !currentList.isEmpty else { return }
        
        let currentIndex: Int
        if let selId = selectedAppId, let idx = currentList.firstIndex(where: { $0.id == selId }) {
            currentIndex = idx
        } else {
            selectedAppId = currentList.first?.id
            return
        }
        
        var nextIndex = currentIndex
        switch direction {
        case .left:
            nextIndex = currentIndex - 1
            if nextIndex < 0 { nextIndex = currentList.count - 1 }
        case .right:
            nextIndex = currentIndex + 1
            if nextIndex >= currentList.count { nextIndex = 0 }
        case .up:
            nextIndex = currentIndex - columnsCount
            if nextIndex < 0 { nextIndex = 0 }
        case .down:
            nextIndex = currentIndex + columnsCount
            if nextIndex >= currentList.count { nextIndex = currentList.count - 1 }
        }
        
        if nextIndex >= 0 && nextIndex < currentList.count {
            selectedAppId = currentList[nextIndex].id
        }
    }
    
    func toggleFolderCollapse(folderId: String) {
        if let idx = apps.firstIndex(where: { $0.id == folderId && $0.isFolder }) {
            var folder = apps[idx]
            folder.isCollapsed = !(folder.isCollapsed ?? false)
            apps[idx] = folder
            saveLayout()
        }
    }
    
    func toggleAppVisibility(path: String, isVisible: Bool) {
        if isVisible {
            hiddenAppPaths.remove(path)
        } else {
            hiddenAppPaths.insert(path)
        }
        saveLayoutPreferences()
    }
    
    func showAllApps() {
        hiddenAppPaths.removeAll()
        saveLayoutPreferences()
    }
    
    func saveLayoutPreferences() {
        UserDefaults.standard.set(Array(hiddenAppPaths), forKey: "mydock.hiddenAppPaths")
        UserDefaults.standard.set(dragBehaviorReorder, forKey: "mydock.dragBehaviorReorder")
        UserDefaults.standard.set(appLabelFontName, forKey: "mydock.appLabelFontName")
        UserDefaults.standard.set(appLabelFontBold, forKey: "mydock.appLabelFontBold")
        UserDefaults.standard.set(runningIndicatorColor, forKey: "mydock.runningIndicatorColor")
        UserDefaults.standard.set(runningIndicatorStyle, forKey: "mydock.runningIndicatorStyle")
        UserDefaults.standard.set(appSortOrder, forKey: "mydock.appSortOrder")
        UserDefaults.standard.set(displayMode, forKey: "mydock.displayMode")
        UserDefaults.standard.set(launchShortcut, forKey: "mydock.launchShortcut")
        UserDefaults.standard.set(launchpadBlurStyle, forKey: "mydock.launchpadBlurStyle")
        UserDefaults.standard.set(launchpadOpacity, forKey: "mydock.launchpadOpacity")
        UserDefaults.standard.set(appLanguage, forKey: "mydock.appLanguage")
        UserDefaults.standard.set(useCustomWallpaper, forKey: "mydock.useCustomWallpaper")
        UserDefaults.standard.set(customWallpaperPath, forKey: "mydock.customWallpaperPath")
        UserDefaults.standard.set(hideDesktopFiles, forKey: "mydock.hideDesktopFiles")
        UserDefaults.standard.set(launchpadContentScale, forKey: "mydock.launchpadContentScale")
        UserDefaults.standard.set(appIconSize, forKey: "mydock.appIconSize")
        UserDefaults.standard.set(appHorizontalSpacing, forKey: "mydock.appHorizontalSpacing")
        UserDefaults.standard.set(appVerticalSpacing, forKey: "mydock.appVerticalSpacing")
        UserDefaults.standard.set(dockClickBehavior, forKey: "mydock.dockClickBehavior")
        UserDefaults.standard.set(statusBarClickBehavior, forKey: "mydock.statusBarClickBehavior")
        self.objectWillChange.send()
    }
    
    func loadLayoutPreferences() {
        if let hidden = UserDefaults.standard.stringArray(forKey: "mydock.hiddenAppPaths") {
            hiddenAppPaths = Set(hidden)
        }
        if UserDefaults.standard.object(forKey: "mydock.dragBehaviorReorder") != nil {
            dragBehaviorReorder = UserDefaults.standard.bool(forKey: "mydock.dragBehaviorReorder")
        }
        if let fontName = UserDefaults.standard.string(forKey: "mydock.appLabelFontName") {
            appLabelFontName = fontName
        }
        if UserDefaults.standard.object(forKey: "mydock.appLabelFontBold") != nil {
            appLabelFontBold = UserDefaults.standard.bool(forKey: "mydock.appLabelFontBold")
        }
        if let indicatorColor = UserDefaults.standard.string(forKey: "mydock.runningIndicatorColor") {
            runningIndicatorColor = indicatorColor
        }
        if let styleName = UserDefaults.standard.string(forKey: "mydock.runningIndicatorStyle") {
            runningIndicatorStyle = styleName
        }
        if let sortOrder = UserDefaults.standard.string(forKey: "mydock.appSortOrder") {
            appSortOrder = sortOrder
        }
        if let mode = UserDefaults.standard.string(forKey: "mydock.displayMode") {
            displayMode = mode
        }
        if let shortcut = UserDefaults.standard.string(forKey: "mydock.launchShortcut") {
            launchShortcut = shortcut
        }
        if let dockClick = UserDefaults.standard.string(forKey: "mydock.dockClickBehavior") {
            dockClickBehavior = dockClick
        }
        if let statusClick = UserDefaults.standard.string(forKey: "mydock.statusBarClickBehavior") {
            statusBarClickBehavior = statusClick
        }
        if let blurStyle = UserDefaults.standard.string(forKey: "mydock.launchpadBlurStyle") {
            launchpadBlurStyle = blurStyle
        }
        if UserDefaults.standard.object(forKey: "mydock.launchpadOpacity") != nil {
            launchpadOpacity = UserDefaults.standard.double(forKey: "mydock.launchpadOpacity")
        }
        if let lang = UserDefaults.standard.string(forKey: "mydock.appLanguage") {
            appLanguage = lang
        } else {
            // Auto detect system preferred language
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            appLanguage = preferred.hasPrefix("zh") ? "zh" : "en"
        }
        if UserDefaults.standard.object(forKey: "mydock.useCustomWallpaper") != nil {
            useCustomWallpaper = UserDefaults.standard.bool(forKey: "mydock.useCustomWallpaper")
        }
        if let wPath = UserDefaults.standard.string(forKey: "mydock.customWallpaperPath") {
            customWallpaperPath = wPath
        }
        if UserDefaults.standard.object(forKey: "mydock.hideDesktopFiles") != nil {
            hideDesktopFiles = UserDefaults.standard.bool(forKey: "mydock.hideDesktopFiles")
        }
        if UserDefaults.standard.object(forKey: "mydock.launchpadContentScale") != nil {
            let s = UserDefaults.standard.double(forKey: "mydock.launchpadContentScale")
            launchpadContentScale = (s >= 0.5 && s <= 0.9) ? s : 0.70
        } else {
            launchpadContentScale = 0.70
        }
        if UserDefaults.standard.object(forKey: "mydock.appIconSize") != nil {
            appIconSize = UserDefaults.standard.double(forKey: "mydock.appIconSize")
        } else {
            appIconSize = 70.0
        }
        if UserDefaults.standard.object(forKey: "mydock.appHorizontalSpacing") != nil {
            appHorizontalSpacing = UserDefaults.standard.double(forKey: "mydock.appHorizontalSpacing")
        } else {
            appHorizontalSpacing = 30.0
        }
        if UserDefaults.standard.object(forKey: "mydock.appVerticalSpacing") != nil {
            appVerticalSpacing = UserDefaults.standard.double(forKey: "mydock.appVerticalSpacing")
        } else {
            appVerticalSpacing = 30.0
        }
    }
    
    func applyDesktopFilesVisibility() {
        let visible = !hideDesktopFiles
        let process = Process()
        process.launchPath = "/usr/bin/defaults"
        process.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "true" : "false"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let killProcess = Process()
            killProcess.launchPath = "/usr/bin/killall"
            killProcess.arguments = ["Finder"]
            killProcess.standardOutput = Pipe()
            killProcess.standardError = Pipe()
            try killProcess.run()
            killProcess.waitUntilExit()
        } catch {
            print("Failed to change desktop files visibility: \(error)")
        }
    }
        
    func backupDockCategories() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let appDir = appSupport.appendingPathComponent("MyDock", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        let backupPath = appDir.appendingPathComponent("dock_categories_backup.json")
        
        do {
            let data = try JSONEncoder().encode(apps)
            try data.write(to: backupPath)
            print("Dock categories backup saved to: \(backupPath.path)")
            // Force settings tab list reload/update
            self.objectWillChange.send()
        } catch {
            print("Failed to backup dock categories: \(error)")
        }
    }
    
    func restoreDockCategories() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let backupPath = appSupport.appendingPathComponent("MyDock/dock_categories_backup.json")
        guard fileManager.fileExists(atPath: backupPath.path) else { return }
        
        do {
            let data = try Data(contentsOf: backupPath)
            let decodedApps = try JSONDecoder().decode([DockItem].self, from: data)
            DispatchQueue.main.async {
                self.apps = decodedApps
                self.saveLayout()
                self.reverifyRunningState()
            }
            print("Dock categories restored from: \(backupPath.path)")
        } catch {
            print("Failed to restore dock categories: \(error)")
        }
    }
    
    func hasDockCategoriesBackup() -> Bool {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let backupPath = appSupport.appendingPathComponent("MyDock/dock_categories_backup.json")
        return fileManager.fileExists(atPath: backupPath.path)
    }

    private func childrenForFolder(_ folderId: String) -> [DockItem]? {
        return apps.first(where: { $0.id == folderId })?.children
    }
}// Global localization dictionary helper
func localizedString(_ key: String, lang: String) -> String {
    let dicts: [String: [String: String]] = [
        "en": [
            "search_placeholder": "Search Applications...",
            "section_applications": "Applications",
            "menu_toggle": "Open Launchpad",
            "menu_preferences": "Preferences...",
            "menu_reload": "Reload Applications List",
            "menu_quit": "Quit Dockpad",
            "btn_group": "Group into Dock",
            "btn_cancel": "Cancel",
            "alert_disband_title": "Disband Dock",
            "alert_disband_msg": "Are you sure you want to disband '%@'? All applications inside will return to the main applications list.",
            "alert_disband_confirm": "Disband",
            "tab_general": "General",
            "tab_collections": "Dock Collections",
            "tab_showhide": "Show / Hide",
            "tab_about": "About",
            "settings_display_mode": "Display Mode",
            "settings_display_mode_desc": "Menubar: lives in status bar. Dock: appears in macOS Dock. Both: icon in both places.",
            "settings_shortcut": "Launch Shortcut",
            "settings_shortcut_desc": "Click the field above, then press your desired key combination.",
            "settings_grid_layout": "Grid Layout",
            "settings_apps_per_row": "Applications Per Row:",
            "settings_app_icon_size": "Application Icon Size:",
            "settings_app_icon_size_desc": "Auto-calculated from content scale and apps per row.",
            "settings_font_style": "Font Style",
            "settings_font_family": "Font Family:",
            "settings_font_bold": "Bold Labels",
            "settings_font_desc": "Choose your typography family and label weight.",
            "settings_indicator_color": "Running Indicator Color",
            "settings_indicator_color_desc": "Select the pill color overlay for active running applications.",
            "settings_language": "Language / 语言",
            "settings_language_desc": "Choose the interface language / 选择界面显示语言",
            "settings_show_in_menubar": "Menubar Icon only",
            "settings_show_in_dock": "Dock Icon only",
            "settings_show_in_both": "Both (Menubar + Dock)",
            "settings_wallpaper": "Launchpad Wallpaper",
            "settings_wallpaper_desc": "Upload a custom background wallpaper image for the Launchpad overlay.",
            "settings_wallpaper_enable": "Use Custom Wallpaper",
            "settings_wallpaper_choose": "Choose Image...",
            "settings_hide_desktop_files": "Hide Desktop Files",
            "settings_hide_desktop_files_desc": "Hides all files and folders on your macOS desktop background.",
            "menu_hide_desktop_files": "Hide Desktop Files",
            "menu_show_desktop_files": "Show Desktop Files",
            "settings_backup_categories_title": "Dock Categories Backup",
            "settings_backup_categories_desc": "Backup and restore your custom folder structures and sorting layout.",
            "btn_backup_categories": "Backup Categories",
            "btn_restore_categories": "Restore Categories"
        ],
        "zh": [
            "search_placeholder": "搜索应用...",
            "section_applications": "应用列表",
            "menu_toggle": "打开启动台",
            "menu_preferences": "偏好设置...",
            "menu_reload": "重载应用列表",
            "menu_quit": "退出 Dockpad",
            "btn_group": "合并到卡片框",
            "btn_cancel": "取消",
            "alert_disband_title": "解散卡片框",
            "alert_disband_msg": "您确定要解散 '%@' 吗？其中的所有应用将返回主应用列表。",
            "alert_disband_confirm": "解散",
            "tab_general": "通用设置",
            "tab_collections": "分类管理",
            "tab_showhide": "显示 / 隐藏",
            "tab_about": "关于",
            "settings_display_mode": "显示模式",
            "settings_display_mode_desc": "状态栏：在顶部状态栏显示。程序坞：在下方 Dock 栏显示。两者：同时在状态栏 and 程序坞显示。",
            "settings_shortcut": "启动快捷键",
            "settings_shortcut_desc": "点击上方输入框，然后按下您想设置的快捷键组合。",
            "settings_grid_layout": "网格布局",
            "settings_apps_per_row": "每行应用个数：",
            "settings_app_icon_size": "应用图标大小：",
            "settings_app_icon_size_desc": "由启动台比例和每行应用数自动计算图标大小。",
            "settings_font_style": "字体样式",
            "settings_font_family": "字体系列：",
            "settings_font_bold": "加粗标签",
            "settings_font_desc": "选择字体样式和标签是否加粗。",
            "settings_indicator_color": "运行状态指示灯颜色",
            "settings_indicator_color_desc": "选择处于活跃运行状态的应用标签背景颜色。",
            "settings_language": "语言 / Language",
            "settings_language_desc": "选择界面显示语言 / Choose the interface language",
            "settings_show_in_menubar": "仅状态栏图标",
            "settings_show_in_dock": "仅 Dock 图标",
            "settings_show_in_both": "两者都显示",
            "settings_wallpaper": "启动台背景壁纸",
            "settings_wallpaper_desc": "为启动台界面上传并设置自定义背景壁纸图像。",
            "settings_wallpaper_enable": "使用自定义背景壁纸",
            "settings_wallpaper_choose": "选择图片...",
            "settings_hide_desktop_files": "隐藏桌面文件",
            "settings_hide_desktop_files_desc": "隐藏 macOS 桌面背景上的所有文件和文件夹。",
            "menu_hide_desktop_files": "隐藏桌面文件",
            "menu_show_desktop_files": "显示桌面文件",
            "settings_backup_categories_title": "Dock 分类备份",
            "settings_backup_categories_desc": "备份和恢复您自定义的卡片框分类结构和应用排序布局。",
            "btn_backup_categories": "备份 Dock 分类",
            "btn_restore_categories": "恢复 Dock 分类"
        ]
    ]
    return dicts[lang]?[key] ?? dicts["en"]?[key] ?? key
}
