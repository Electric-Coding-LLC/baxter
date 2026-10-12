import AppKit
import SwiftUI

@MainActor
final class BaxterWorkspaceWindowCoordinator: ObservableObject {
    typealias WindowPresenter = @MainActor (NSWindow) -> Void

    private weak var window: NSWindow?
    private var presentationPending = false
    private let presentWindow: WindowPresenter

    init(presentWindow: @escaping WindowPresenter = BaxterWorkspaceWindowCoordinator.defaultPresenter) {
        self.presentWindow = presentWindow
    }

    func register(_ window: NSWindow) {
        self.window = window
        presentIfNeeded()
    }

    func requestPresentation() {
        presentationPending = true
        presentIfNeeded()
    }

    private func presentIfNeeded() {
        guard presentationPending, let window else {
            return
        }
        presentationPending = false
        presentWindow(window)
    }

    private static func defaultPresenter(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct WorkspaceWindowRegistration: NSViewRepresentable {
    let windowCoordinator: BaxterWorkspaceWindowCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = { window in
            windowCoordinator.register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowChange?(window)
        }
    }
}
