import Foundation

struct DockItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var bundleId: String
    var path: String
    var isRunning: Bool
    var isFolder: Bool
    var children: [DockItem]?
    var isCollapsed: Bool? = false
    
    enum CodingKeys: String, CodingKey {
        case id, name, bundleId, path, isRunning, isFolder, children, isCollapsed
    }
    
    init(id: String, name: String, bundleId: String, path: String, isRunning: Bool = false, isFolder: Bool = false, children: [DockItem]? = nil, isCollapsed: Bool? = false) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.path = path
        self.isRunning = isRunning
        self.isFolder = isFolder
        self.children = children
        self.isCollapsed = isCollapsed
    }
    
    // Self-healing decoder that provides default values for missing keys (older storage schemas)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.bundleId = try container.decode(String.self, forKey: .bundleId)
        self.path = try container.decode(String.self, forKey: .path)
        self.isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        self.isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        self.children = try container.decodeIfPresent([DockItem].self, forKey: .children)
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
    
    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        return lhs.id == rhs.id
    }
}

class DockController {
    static let shared = DockController()
    
    private let plistPath: URL
    private let backupPlistPath: URL
    
    private init() {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.plistPath = libraryDir.appendingPathComponent("Preferences/com.apple.dock.plist")
        self.backupPlistPath = libraryDir.appendingPathComponent("Preferences/com.apple.dock.backup.plist")
    }
    
    func backupDock() {
        if UserDefaults.standard.object(forKey: "mydock.originalAutohide") == nil {
            let isAutohide = shell("defaults read com.apple.dock autohide")?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            UserDefaults.standard.set(isAutohide, forKey: "mydock.originalAutohide")
            print("DockController: Original autohide preference (\(isAutohide)) backed up to UserDefaults.")
        }
    }
    
    func restoreDock() {
        print("DockController: Restoring native Dock settings...")
        shell("defaults delete com.apple.dock autohide-delay")
        let originalAutohide = UserDefaults.standard.object(forKey: "mydock.originalAutohide") as? Bool ?? false
        shell("defaults write com.apple.dock autohide -bool \(originalAutohide ? "true" : "false")")
        shell("killall Dock")
        UserDefaults.standard.removeObject(forKey: "mydock.originalAutohide")
    }
    
    func hideNativeDock() {
        print("DockController: Hiding native Dock...")
        backupDock()
        shell("defaults write com.apple.dock autohide -bool true")
        shell("defaults write com.apple.dock autohide-delay -float 1000")
        shell("killall Dock")
    }
    
    // Scans `/Applications` and `/System/Applications` two levels deep using contentsOfDirectory.
    // NOTE: FileManager.enumerator with .skipsPackageDescendants silently skips system-protected
    // .app bundles (e.g. Safari), so we use explicit contentsOfDirectory instead.
    func readNativeDockApps() -> [DockItem] {
        let fileManager = FileManager.default
        let rootPaths = ["/Applications", "/System/Applications"]
        var apps: [DockItem] = []
        var seenPaths = Set<String>()
        
        func processAppURL(_ fileURL: URL) {
            let path = fileURL.path
            guard !seenPaths.contains(path) else { return }
            seenPaths.insert(path)
            
            let displayName = fileManager.displayName(atPath: path)
            guard !displayName.hasPrefix(".") else { return }
            
            var bundleId = ""
            if let bundle = Bundle(path: path) {
                bundleId = bundle.bundleIdentifier ?? ""
            }
            if bundleId.isEmpty {
                let plistURL = fileURL.appendingPathComponent("Contents/Info.plist")
                if let plistDict = NSDictionary(contentsOf: plistURL),
                   let bid = plistDict["CFBundleIdentifier"] as? String {
                    bundleId = bid
                }
            }
            guard !bundleId.isEmpty else { return }
            
            let cleanName = displayName.replacingOccurrences(of: ".app", with: "")
            let item = DockItem(
                id: fileURL.lastPathComponent,
                name: cleanName,
                bundleId: bundleId,
                path: path
            )
            apps.append(item)
        }
        
        for rootPath in rootPaths {
            guard let topLevel = try? fileManager.contentsOfDirectory(atPath: rootPath) else { continue }
            for entry in topLevel {
                let entryPath = "\(rootPath)/\(entry)"
                if entry.hasSuffix(".app") {
                    // Top-level .app bundle
                    processAppURL(URL(fileURLWithPath: entryPath))
                } else {
                    // Sub-directory (e.g. Utilities) — scan one level deeper
                    var isDir: ObjCBool = false
                    guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    guard let subLevel = try? fileManager.contentsOfDirectory(atPath: entryPath) else { continue }
                    for subEntry in subLevel where subEntry.hasSuffix(".app") {
                        processAppURL(URL(fileURLWithPath: "\(entryPath)/\(subEntry)"))
                    }
                }
            }
        }
        
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    @discardableResult
    private func shell(_ command: String) -> String? {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
