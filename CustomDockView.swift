import SwiftUI
import AppKit

// Contents of the folder popover (re-used for loose folder popover compatibility)
struct FolderContentsView: View {
    let folder: DockItem
    @ObservedObject private var appMonitor = AppMonitor.shared
    
    var body: some View {
        VStack(spacing: 8) {
            TextField("Dock Name", text: Binding(
                get: { folder.name },
                set: { appMonitor.renameFolder(folderId: folder.id, newName: $0) }
            ))
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.primary)
            .multilineTextAlignment(.center)
            .frame(width: 140)
            .padding(4)
            .background(Color.white.opacity(0.12))
            .cornerRadius(6)
            .padding(.top, 6)
            
            if let children = folder.children {
                let columns = Array(repeating: GridItem(.fixed(80), spacing: 12), count: min(children.count, 4))
                
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(children) { child in
                        CustomDockItemView(
                            item: child,
                            isRunning: !child.isFolder && appMonitor.runningBundleIds.contains(child.bundleId),
                            inFolderId: folder.id
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        )
    }
}

// Custom Folder Card View rendering the folder as an arbitrary rectangle box matching the apps grid length
struct FolderCardView: View {
    let folder: DockItem
    let containerWidth: CGFloat
    @ObservedObject var appMonitor = AppMonitor.shared
    
    // Compute columns dynamically based on appsPerRow preference to distribute them across containerWidth
    private var columns: [GridItem] {
        let n = appMonitor.appsPerRow
        let spacing = CGFloat(appMonitor.appHorizontalSpacing)
        let colWidth = CGFloat(appMonitor.appIconSize)
        return Array(repeating: GridItem(.fixed(colWidth), spacing: spacing), count: n)
    }
    
    // Dynamic Folder Title Font mapper matching preferences
    private var folderTitleFont: Font {
        let weight: Font.Weight = appMonitor.appLabelFontBold ? .bold : .regular
        switch appMonitor.appLabelFontName {
        case "Rounded":
            return .system(size: 15, weight: weight, design: .rounded)
        case "Monospace":
            return .system(size: 15, weight: weight, design: .monospaced)
        case "Serif":
            return .system(size: 15, weight: weight, design: .serif)
        default:
            return .system(size: 15, weight: weight, design: .default)
        }
    }
    
    // Sort folder children outside ViewBuilder (switch not allowed inside ViewBuilder closures)
    private func sortedItems(from children: [DockItem]) -> [DockItem] {
        var items = children
        switch appMonitor.appSortOrder {
        case "Name":
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "AddTime":
            items = items.reversed()
        default:
            break
        }
        if folder.isCollapsed ?? false {
            items = Array(items.prefix(appMonitor.appsPerRow))
        }
        return items
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { // Compact spacing to bring title/buttons closer to the frame
            HStack {
                // Folder title edit field (outside of glass frame)
                TextField("Dock Name", text: Binding(
                    get: { folder.name },
                    set: { appMonitor.renameFolder(folderId: folder.id, newName: $0) }
                ))
                .textFieldStyle(PlainTextFieldStyle())
                .font(folderTitleFont)
                .foregroundColor(appMonitor.launchpadBlurStyle == "Dark" ? .white : .black)
                .frame(width: 250)
                
                Spacer()
                
                // Collapse/Expand Button (Icon only, outside of glass frame)
                Button(action: {
                    appMonitor.toggleFolderCollapse(folderId: folder.id)
                }) {
                    Image(systemName: (folder.isCollapsed ?? false) ? "chevron.down.circle" : "chevron.up.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue.opacity(0.8))
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)
                .help((folder.isCollapsed ?? false) ? "Expand Folder" : "Collapse to Row")
                .padding(.trailing, 12)
                
                // Button to disband folder back into loose apps (Icon only, outside of glass frame)
                Button(action: {
                    appMonitor.folderIdToDisband = folder.id
                }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)
                .help("Disband Folder")
            }
            .padding(.horizontal, 8) // Align with grid edges
            
            if let children = folder.children {
                let itemsToShow = sortedItems(from: children)
                
                LazyVGrid(columns: columns, spacing: CGFloat(appMonitor.appVerticalSpacing)) {
                    ForEach(itemsToShow) { child in
                        CustomDockItemView(
                            item: child,
                            isRunning: !child.isFolder && appMonitor.runningBundleIds.contains(child.bundleId),
                            inFolderId: folder.id
                        )
                    }
                }
                .padding(16) // Padding inside the border frame
                .background(
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                            .opacity(0.55)
                        
                        let solidColor = appMonitor.launchpadBlurStyle == "Dark" ? Color(white: 0.18) : Color.white
                        solidColor
                            .opacity(appMonitor.launchpadOpacity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
        }
        .frame(width: containerWidth) // Force folder card width to match top-level apps grid width exactly
    }
}

// Drag & Drop reordering support for folders
struct FolderDropDelegate: DropDelegate {
    let targetFolder: DockItem
    let appMonitor: AppMonitor
    
    func dropEntered(info: DropInfo) {
        guard let dragged = appMonitor.draggedItem else { return }
        guard dragged.id != targetFolder.id else { return }
        
        if dragged.isFolder && targetFolder.isFolder {
            if let fromIdx = appMonitor.apps.firstIndex(where: { $0.id == dragged.id }),
               let toIdx = appMonitor.apps.firstIndex(where: { $0.id == targetFolder.id }) {
                if fromIdx != toIdx {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        appMonitor.moveApp(draggedId: dragged.id, targetId: targetFolder.id)
                    }
                }
            }
        } else if !dragged.isFolder {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appMonitor.moveAppToFolderEnd(appId: dragged.id, folderId: targetFolder.id)
            }
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        appMonitor.draggedItem = nil
        return true
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = appMonitor.draggedItem else { return false }
        return dragged.id != targetFolder.id
    }
}

struct ItemDropDelegate: DropDelegate {
    let targetItem: DockItem
    let appMonitor: AppMonitor
    
    func dropEntered(info: DropInfo) {
        guard let dragged = appMonitor.draggedItem else { return }
        guard !dragged.isFolder else { return } // Block folder drag from entering normal item grid
        guard dragged.id != targetItem.id else { return }
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            appMonitor.moveApp(draggedId: dragged.id, targetId: targetItem.id)
        }
    }
    
    func dropExited(info: DropInfo) {}
    
    func performDrop(info: DropInfo) -> Bool {
        appMonitor.draggedItem = nil
        return true
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = appMonitor.draggedItem else { return false }
        guard !dragged.isFolder else { return false } // Block folder drop validation on normal items
        return dragged.id != targetItem.id
    }
}

struct CustomDockItemView: View {
    let item: DockItem
    let isRunning: Bool
    var inFolderId: String? = nil
    @ObservedObject private var appMonitor = AppMonitor.shared
    
    // Dynamic Font face and bold weight design mapper
    private var labelFont: Font {
        let weight: Font.Weight = appMonitor.appLabelFontBold ? .bold : .regular
        switch appMonitor.appLabelFontName {
        case "Rounded":
            return .system(size: 10, weight: weight, design: .rounded)
        case "Monospace":
            return .system(size: 10, weight: weight, design: .monospaced)
        case "Serif":
            return .system(size: 10, weight: weight, design: .serif)
        default:
            return .system(size: 10, weight: weight, design: .default)
        }
    }
    
    // Dynamic indicator dot color mapper
    private var indicatorColor: Color {
        switch appMonitor.runningIndicatorColor {
        case "Green":
            return .green
        case "Red":
            return .red
        case "Orange":
            return .orange
        case "Dark":
            return .black
        default:
            return .blue
        }
    }
    
    var body: some View {
        let isHovered = appMonitor.hoveredAppId == item.id
        let isSelected = appMonitor.selectedAppId == item.id
        let isFolderSelection = appMonitor.isFolderCreationMode
        let isAppSelected = appMonitor.selectedAppIdsForFolder.contains(item.id)
        let iconSize = appMonitor.calculatedIconSize
        let cellW: CGFloat = iconSize
        let cellSize: CGFloat = iconSize + 36
        
        VStack(spacing: 2) {
            Group {
                Image(nsImage: loadIcon())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .scaleEffect(isHovered ? 1.08 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
            }
            .frame(width: iconSize + 8, height: iconSize + 4, alignment: .center)
            .overlay(
                Group {
                    if isFolderSelection && !item.isFolder {
                        Image(systemName: isAppSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(isAppSelected ? .green : .white.opacity(0.8))
                            .background(Circle().fill(Color.black.opacity(0.4)))
                            .padding(4)
                    }
                },
                alignment: .topTrailing
            )
            
            Text(item.name)
                .font(labelFont)
                .foregroundColor(isRunning ? .white : (appMonitor.launchpadBlurStyle == "Dark" ? .white : .black))
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isRunning ? indicatorColor : Color.clear
                )
                .clipShape(Capsule())
                .frame(width: cellW)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(isSelected ? 0.20 : (isHovered ? 0.10 : 0.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(isSelected ? 0.40 : 0.0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .help(item.name)
        .contextMenu {
            if isRunning {
                Button(appMonitor.appLanguage == "zh" ? "退出应用" : "Quit Application") {
                    appMonitor.quitApp(bundleId: item.bundleId)
                }
                Divider()
            }
            
            if let folderId = inFolderId {
                Button(appMonitor.appLanguage == "zh" ? "移出文件夹" : "Move out of Folder") {
                    appMonitor.removeItemFromFolder(itemId: item.id, folderId: folderId)
                }
            } else {
                Button(appMonitor.appLanguage == "zh" ? "从启动台隐藏应用" : "Hide App from Launchpad") {
                    appMonitor.toggleAppVisibility(path: item.path, isVisible: false)
                }
            }
        }
        .onHover { hover in
            if hover {
                appMonitor.hoveredAppId = item.id
                appMonitor.selectedAppId = item.id
            } else if appMonitor.hoveredAppId == item.id {
                appMonitor.hoveredAppId = nil
            }
        }
        .onTapGesture {
            if isFolderSelection {
                if !item.isFolder {
                    if isAppSelected {
                        appMonitor.selectedAppIdsForFolder.remove(item.id)
                    } else {
                        appMonitor.selectedAppIdsForFolder.insert(item.id)
                    }
                }
            } else {
                appMonitor.launchApp(bundleId: item.bundleId, path: item.path)
            }
        }
        .onDrag({
            appMonitor.draggedItem = item
            return NSItemProvider(object: item.id as NSString)
        }, preview: {
            Color.clear
                .frame(width: 1, height: 1)
        })
        .onDrop(of: [.text], delegate: ItemDropDelegate(targetItem: item, appMonitor: appMonitor))
        .frame(width: cellW, height: cellSize)
        .opacity(appMonitor.draggedItem?.id == item.id ? 0.001 : 1.0)
    }
    
    private func loadIcon() -> NSImage {
        if !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path) {
            return NSWorkspace.shared.icon(forFile: item.path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFileType: "app")
    }
}

struct CustomDockView: View {
    @ObservedObject private var appMonitor = AppMonitor.shared
    
    // Compute columns dynamically based on appsPerRow preference to distribute them across totalWidth
    private func columns(for totalWidth: CGFloat) -> [GridItem] {
        let n = appMonitor.appsPerRow
        let spacing = CGFloat(appMonitor.appHorizontalSpacing)
        let colWidth = CGFloat(appMonitor.appIconSize)
        return Array(repeating: GridItem(.fixed(colWidth), spacing: spacing), count: n)
    }
    
    private var folders: [DockItem] {
        appMonitor.filteredApps.filter { $0.isFolder }
    }
    
    private var looseApps: [DockItem] {
        appMonitor.filteredApps.filter { !$0.isFolder }
    }
    
    private func loadIcon(for item: DockItem) -> NSImage {
        if !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path) {
            return NSWorkspace.shared.icon(forFile: item.path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFileType: "app")
    }
    
    private var dragLocalPosition: CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let x = appMonitor.dragMouseScreenLocation.x - screen.frame.minX
        let y = screen.frame.maxY - appMonitor.dragMouseScreenLocation.y
        return CGPoint(x: x, y: y)
    }
    
    private var sectionHeaderFont: Font {
        let weight: Font.Weight = appMonitor.appLabelFontBold ? .heavy : .regular
        switch appMonitor.appLabelFontName {
        case "Rounded":
            return .system(size: 16, weight: weight, design: .rounded)
        case "Monospace":
            return .system(size: 16, weight: weight, design: .monospaced)
        case "Serif":
            return .system(size: 16, weight: weight, design: .serif)
        default:
            return .system(size: 16, weight: weight, design: .default)
        }
    }
    
    var body: some View {
        let bindingSearchText = Binding<String>(
            get: { appMonitor.searchText },
            set: { appMonitor.searchText = $0 }
        )
        
        GeometryReader { screenGeo in
            let preferredWidth = screenGeo.size.width * CGFloat(appMonitor.launchpadContentScale)
            
            ZStack {
            // Background layer — purely decorative, no hit testing
            if appMonitor.useCustomWallpaper,
               !appMonitor.customWallpaperPath.isEmpty,
               let nsImg = NSImage(contentsOfFile: appMonitor.customWallpaperPath) {
                GeometryReader { geo in
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .edgesIgnoringSafeArea(.all)
            } else {
                // Fullscreen system blurred backdrop
                VisualEffectView(material: VisualEffectView.material(for: appMonitor.launchpadBlurStyle), blendingMode: .behindWindow, state: .active)
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Transparent tap-to-dismiss backdrop — use simultaneousGesture so card/icon taps still work
            Color.clear
                .contentShape(Rectangle())
                .edgesIgnoringSafeArea(.all)
                .simultaneousGesture(TapGesture().onEnded {
                    NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                })
            
            VStack(spacing: 20) {
                // Top Search Bar and Folder Creation Controls
                    let topWeight: Font.Weight = appMonitor.appLabelFontBold ? .bold : .regular
                    HStack(spacing: 20) {
                        if appMonitor.isFolderCreationMode {
                        HStack(spacing: 12) {
                            Button(action: {
                                appMonitor.createFolderFromSelected(name: appMonitor.appLanguage == "zh" ? "新建分类" : "New Folder")
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.grid.2x2.fill")
                                    Text("\(localizedString("btn_group", lang: appMonitor.appLanguage)) (\(appMonitor.selectedAppIdsForFolder.count))")
                                }
                                .font(.system(size: 13, weight: topWeight))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                            .disabled(appMonitor.selectedAppIdsForFolder.isEmpty)
                            
                            Button(action: {
                                appMonitor.selectedAppIdsForFolder.removeAll()
                                appMonitor.isFolderCreationMode = false
                            }) {
                                Text(localizedString("btn_cancel", lang: appMonitor.appLanguage))
                                    .font(.system(size: 13, weight: topWeight))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.12))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                        }
                    } else {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white.opacity(0.6))
                            TextField(localizedString("search_placeholder", lang: appMonitor.appLanguage), text: bindingSearchText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 15, weight: topWeight))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(width: 320)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                        
                        Button(action: {
                            appMonitor.isFolderCreationMode = true
                            appMonitor.selectedAppIdsForFolder.removeAll()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.grid.2x2.fill")
                                Text(appMonitor.appLanguage == "zh" ? "分类整理" : "Group Apps")
                            }
                            .font(.system(size: 13, weight: topWeight))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(appMonitor.launchpadBlurStyle == "Light" ? Color.black.opacity(0.06) : Color.white.opacity(0.15))
                            .foregroundColor(appMonitor.launchpadBlurStyle == "Light" ? .black : .white)
                            .cornerRadius(10)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .focusable(false)
                        
                        // --- Sort Order Buttons (text-only) + Settings gear ---
                        HStack(spacing: 6) {
                            ForEach([("None", "Manual"), ("Name", "Name"), ("AddTime", "Time")], id: \.0) { order, label in
                                let isSelected = appMonitor.appSortOrder == order
                                let isLight = appMonitor.launchpadBlurStyle == "Light"
                                
                                Button(action: {
                                    appMonitor.appSortOrder = order
                                    appMonitor.saveLayoutPreferences()
                                }) {
                                    Text(label)
                                        .font(.system(size: 11, weight: topWeight))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(isSelected
                                            ? Color.green
                                            : (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.12)))
                                        .foregroundColor(isSelected
                                            ? .white
                                            : (isLight ? .black : .white))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .focusable(false)
                            }
                            
                            // Settings gear button — close launchpad then open prefs
                            let isLight = appMonitor.launchpadBlurStyle == "Light"
                            Button(action: {
                                NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    NotificationCenter.default.post(name: Notification.Name("ShowPreferences"), object: nil)
                                }
                            }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 13, weight: topWeight))
                                    .foregroundColor(isLight ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
                                    .padding(6)
                                    .background(isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.12))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                            .help("Preferences")
                            
                            // Reload Apps button
                            Button(action: {
                                appMonitor.reloadApps()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: topWeight))
                                    .foregroundColor(isLight ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
                                    .padding(6)
                                    .background(isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.12))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                            .help(appMonitor.appLanguage == "zh" ? "更新加载" : "Reload Apps")
                        }
                    }
                }
                .padding(.top, 44)
                .onTapGesture { }
                
                // Scrollable Grid utilizing geometry height mapping
                GeometryReader { scrollGeo in
                    ScrollView(.vertical, showsIndicators: true) {
                        ZStack(alignment: .top) {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(minHeight: scrollGeo.size.height)
                                .onTapGesture {
                                    NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                                }

                            VStack(spacing: 30) {
                                // 1. Render all folder cards first
                                ForEach(folders) { folder in
                                    let isBeingDragged = appMonitor.draggedItem?.id == folder.id
                                    FolderCardView(folder: folder, containerWidth: preferredWidth)
                                        .opacity(isBeingDragged ? 0.001 : 1.0)
                                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isBeingDragged)
                                        .onDrag({
                                            appMonitor.draggedItem = folder
                                            return NSItemProvider(object: folder.id as NSString)
                                        }, preview: {
                                            FolderCardView(folder: folder, containerWidth: preferredWidth)
                                                .scaleEffect(0.90) // Shrink the visual box under the mouse cursor
                                        })
                                        .onDrop(of: [.text], delegate: FolderDropDelegate(targetFolder: folder, appMonitor: appMonitor))
                                }

                                // 2. Render all un-grouped applications at the bottom
                                if !looseApps.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(localizedString("section_applications", lang: appMonitor.appLanguage))
                                            .font(sectionHeaderFont)
                                            .foregroundColor(appMonitor.launchpadBlurStyle == "Dark" ? .white : .black)
                                            .padding(.horizontal, 8)

                                        LazyVGrid(columns: columns(for: preferredWidth), spacing: CGFloat(appMonitor.appVerticalSpacing)) {
                                            ForEach(looseApps) { item in
                                                CustomDockItemView(
                                                    item: item,
                                                    isRunning: !item.isFolder && appMonitor.runningBundleIds.contains(item.bundleId)
                                                )
                                            }
                                        }
                                        .padding(16)
                                        .background(
                                            ZStack {
                                                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                                                    .opacity(0.55)

                                                let solidColor = appMonitor.launchpadBlurStyle == "Dark" ? Color(white: 0.18) : Color.white
                                                solidColor
                                                    .opacity(appMonitor.launchpadOpacity)
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 20))
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                                            }
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 20)
                                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                        )
                                    }
                                    .frame(width: preferredWidth)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        NotificationCenter.default.post(name: Notification.Name("HideLaunchpad"), object: nil)
                                    }
                            )
                        }
                    }
                    .frame(width: screenGeo.size.width)
                    .scrollIndicators(.visible)
                }
            }
            .frame(width: screenGeo.size.width)

            // Custom floating drag preview that follows the mouse cursor and stays visible during dragging
            if let dragged = appMonitor.draggedItem {
                Image(nsImage: loadIcon(for: dragged))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: appMonitor.calculatedIconSize, height: appMonitor.calculatedIconSize)
                    .position(dragLocalPosition)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            if let dragged = appMonitor.draggedItem, !dragged.isFolder {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    appMonitor.moveAppToTopLevel(itemId: dragged.id)
                }
            }
            appMonitor.draggedItem = nil
            return true
        }
        .onAppear {
            appMonitor.loadLayout()
        }
        .alert(isPresented: Binding(
            get: { appMonitor.folderIdToDisband != nil },
            set: { if !$0 { appMonitor.folderIdToDisband = nil } }
        )) {
            let folderName = appMonitor.apps.first(where: { $0.id == appMonitor.folderIdToDisband })?.name ?? "Dock"
            let disbandTitle = localizedString("alert_disband_title", lang: appMonitor.appLanguage)
            let rawMsg = localizedString("alert_disband_msg", lang: appMonitor.appLanguage)
            let disbandMsg = rawMsg.contains("%@") ? String(format: rawMsg, folderName) : rawMsg.replacingOccurrences(of: "'\(folderName)'", with: "'\(folderName)'")
            
            return Alert(
                title: Text(disbandTitle),
                message: Text(disbandMsg),
                primaryButton: .destructive(Text(localizedString("alert_disband_confirm", lang: appMonitor.appLanguage))) {
                    if let folderId = appMonitor.folderIdToDisband {
                        appMonitor.disbandFolder(folderId: folderId)
                    }
                },
                secondaryButton: .cancel(Text(localizedString("btn_cancel", lang: appMonitor.appLanguage)))
            )
        }
        }
    }
}
