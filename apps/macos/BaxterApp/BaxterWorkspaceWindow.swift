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

struct WorkspaceWindowTitleSync: NSViewRepresentable {
    let title: String
    let trailingTitle: String
    let windowCoordinator: BaxterWorkspaceWindowCoordinator

    final class Coordinator {
        weak var window: NSWindow?
        weak var trailingLabel: NSTextField?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }
            synchronizeWindow(window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }
            synchronizeWindow(window, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.trailingLabel?.removeFromSuperview()
    }

    private func synchronizeWindow(_ window: NSWindow, coordinator: Coordinator) {
        windowCoordinator.register(window)
        removeRightTitlebarAccessories(from: window)
        window.title = title
        installOrUpdateTrailingLabel(on: window, coordinator: coordinator)
    }

    private func removeRightTitlebarAccessories(from window: NSWindow) {
        let indexedAccessories = Array(window.titlebarAccessoryViewControllers.enumerated())
        for (index, accessory) in indexedAccessories.reversed() where accessory.layoutAttribute == .right {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    private func installOrUpdateTrailingLabel(on window: NSWindow, coordinator: Coordinator) {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else {
            return
        }

        let label: NSTextField
        if let existing = coordinator.trailingLabel, existing.superview === titlebarView {
            label = existing
        } else {
            let created = NSTextField(labelWithString: trailingTitle)
            created.identifier = NSUserInterfaceItemIdentifier("baxter.trailing.title.label")
            created.font = NSFont.systemFont(
                ofSize: NSFont.titleBarFont(ofSize: NSFont.systemFontSize).pointSize,
                weight: .semibold
            )
            created.textColor = .labelColor
            created.alignment = .right
            created.lineBreakMode = .byTruncatingTail
            created.translatesAutoresizingMaskIntoConstraints = false

            titlebarView.addSubview(created)
            NSLayoutConstraint.activate([
                created.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -24),
                created.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor)
            ])

            coordinator.trailingLabel = created
            coordinator.window = window
            label = created
        }

        label.stringValue = trailingTitle
        label.sizeToFit()
    }
}
