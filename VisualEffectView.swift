import SwiftUI
import AppKit

class ClickThroughVisualEffectView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    
    static func material(for style: String) -> NSVisualEffectView.Material {
        switch style {
        case "Light": return .light
        default: return .dark
        }
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = ClickThroughVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
