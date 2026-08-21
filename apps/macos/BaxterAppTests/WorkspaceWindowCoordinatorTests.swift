import AppKit
import XCTest
@testable import BaxterApp

@MainActor
final class WorkspaceWindowCoordinatorTests: XCTestCase {
    func testPresentationWaitsForWindowRegistration() {
        var presentedWindow: NSWindow?
        let coordinator = BaxterWorkspaceWindowCoordinator { presentedWindow = $0 }
        let window = NSWindow()

        coordinator.requestPresentation()
        XCTAssertNil(presentedWindow)

        coordinator.register(window)
        XCTAssertTrue(presentedWindow === window)
    }

    func testPresentationUsesRegisteredWindowImmediately() {
        var presentedWindow: NSWindow?
        let coordinator = BaxterWorkspaceWindowCoordinator { presentedWindow = $0 }
        let window = NSWindow()

        coordinator.register(window)
        coordinator.requestPresentation()

        XCTAssertTrue(presentedWindow === window)
    }
}
