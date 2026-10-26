// One viewer window: an NSWindow + its own ViewerController targeting one box.
//
// Multiple of these can be open at once (one per workstation — the single-session
// limit is per-box, enforced by AppDelegate). Closing a window behaves like a mini
// quit: it clean-disconnects that box's slot BEFORE the webView is torn down, by
// deferring the actual close until the disconnect flush completes.

import AppKit

@MainActor
final class ViewerWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let controller: ViewerController
    private weak var appDelegate: AppDelegate?
    private var closing = false

    init(workstation: Workstation, appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.controller = ViewerController(workstation: workstation)
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 900)
        self.window = NSWindow(contentRect: rect,
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
        super.init()
        window.backgroundColor = .black   // no white flash behind the stream
        window.contentView = controller.makeWebView(frame: rect)
        window.delegate = self
        window.isReleasedWhenClosed = false
        updateTitle()
        controller.onWorkstationChange = { [weak self] in self?.updateTitle() }
    }

    var workstation: Workstation { controller.workstation }

    func updateTitle() {
        var t = "Isaac Connect — \(controller.workstation.name)"
        if let note = controller.statusNote { t += " · \(note)" }   // e.g. "· not running"
        window.title = t
    }

    /// Order the window in (cascading off a sibling if given) and start streaming.
    func show(cascadeFrom sibling: NSWindow?) {
        if let sibling = sibling {
            let origin = NSPoint(x: sibling.frame.minX + 32, y: sibling.frame.maxY - 32)
            window.setFrameTopLeftPoint(origin)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        controller.start()
    }

    // Defer the real close until the box's slot is freed, so we don't orphan it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        closing = true
        controller.disconnect { [weak self] in
            guard let self = self else { return }
            self.controller.teardown()   // release web view + handler + loopback server
            self.window.delegate = nil
            self.window.close()
            self.appDelegate?.windowDidClose(self)
        }
        return false
    }

    /// Used on app quit: free the slot + release resources, then run completion.
    func disconnectForQuit(completion: @escaping () -> Void) {
        controller.disconnect { [weak self] in
            self?.controller.teardown()
            completion()
        }
    }
}
