import AppKit
import SwiftUI

/// Owns the standalone queue window. A plain NSWindow is used instead of a
/// SwiftUI `Window` scene because `openWindow` did not fire reliably from the
/// main window's onAppear.
final class QueueWindowController {
    static let shared = QueueWindowController()

    private var window: NSWindow?
    private weak var state: AppState?

    func show(state: AppState) {
        self.state = state
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: QueueView(state: state))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "任务队列"
        // SwiftUI's preferredColorScheme does not apply to a plain NSWindow.
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1)
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("SIAQueueWindow")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
