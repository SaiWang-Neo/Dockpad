import AppKit
import SwiftUI

class CustomDockPanel: NSPanel {
    init(contentView: NSView) {
        // Start with the full screen frame
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        
        super.init(
            contentRect: screenRect,
            styleMask: [.borderless, .nonactivatingPanel], // nonactivatingPanel avoids stealing app focus
            backing: .buffered,
            defer: false
        )
        
        self.level = .statusBar // Use statusBar level so it receives drag-and-drop events (assistiveTechHighWindow is bypassed by the OS drag manager)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        
        // Ensure it spans all spaces/desktops, doesn't hide Stage Manager apps, and sits on top.
        // We do NOT use .transient here because .transient windows are automatically hidden by AppKit
        // when the app resigns active, which happens immediately when a drag-and-drop operation starts.
        self.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        
        self.contentView = contentView
        
        // Listen to screen changes to scale and center correctly
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        reposition()
    }
    
    @objc private func screenParametersChanged() {
        reposition()
    }
    
    // Fill the current active screen
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        
        DispatchQueue.main.async {
            self.setFrame(screenFrame, display: true, animate: false)
        }
    }

    
    // canBecomeKey=true is required so the search TextField can receive keyboard input.
    // However we NEVER want this panel to be the "main" window (that would steal the menu bar).
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }
    
    // Always show via orderFrontRegardless so the app is never activated.
    // This is the key fix: even if someone calls orderFront, we redirect to the non-activating variant.
    override func orderFront(_ sender: Any?) {
        self.orderFrontRegardless()
    }
    
    // Intercept keyboard arrow keys, enter, and escape
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            self.orderOut(nil)
        case 36: // Enter
            AppMonitor.shared.launchSelectedApp()
        case 123: // Left Arrow
            AppMonitor.shared.moveSelection(direction: .left)
        case 124: // Right Arrow
            AppMonitor.shared.moveSelection(direction: .right)
        case 125: // Down Arrow
            AppMonitor.shared.moveSelection(direction: .down)
        case 126: // Up Arrow
            AppMonitor.shared.moveSelection(direction: .up)
        default:
            // Send typing text key events directly to SwiftUI search box
            super.keyDown(with: event)
        }
    }
}
