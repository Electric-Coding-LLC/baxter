import XCTest
@testable import BaxterApp

@MainActor
final class BaxterMenuStatusTests: XCTestCase {
    private func makeModel(hasConfig: Bool = true) -> BackupStatusModel {
        let model = BackupStatusModel(hasConfigFile: { hasConfig }, autoStartPolling: false)
        model.connectionState = .connected
        model.daemonServiceState = .running
        model.isDaemonReachable = true
        return model
    }

    func testHealthyStatusHasNoWarningsAndAllowsBackup() {
        let model = makeModel()
        let status = BaxterMenuStatus(model: model)

        XCTAssertEqual(
            status.statusLines,
            ["Baxter is running", "Backup is idle", "Last Backup: Never", "Next Backup: Manual"]
        )
        XCTAssertTrue(status.warnings.isEmpty)
        XCTAssertTrue(status.canRunBackup)
        XCTAssertNil(status.runBackupDisabledReason)
        XCTAssertFalse(status.canStartDaemon)
        XCTAssertTrue(status.canStopDaemon)
    }

    func testFailedOverdueAndSkippedEachAddWarning() {
        let model = makeModel()
        model.state = .failed
        model.lastError = "bucket unreachable"
        model.backupOverdue = true
        model.daysSinceLastBackup = 9
        model.lastBackupSkippedCount = 3

        XCTAssertEqual(
            BaxterMenuStatus(model: model).warnings,
            [
                "Backup failed: bucket unreachable",
                "No successful backup in 9 days.",
                "The last backup skipped 3 files it could not read.",
            ]
        )
    }

    func testFailedBackupWithoutErrorPointsToDiagnostics() {
        let model = makeModel()
        model.state = .failed

        XCTAssertEqual(
            BaxterMenuStatus(model: model).warnings,
            ["The last backup failed. Open Diagnostics for details."]
        )
    }

    func testRunningBackupShowsProgressAndBlocksAnotherRun() {
        let model = makeModel()
        model.state = .running
        model.backupUploaded = 2
        model.backupTotal = 5
        let status = BaxterMenuStatus(model: model)

        XCTAssertEqual(Array(status.statusLines.prefix(3)), [
            "Baxter is running",
            "Backup is running (2/5)",
            "Uploading changed files",
        ])
        XCTAssertFalse(status.canRunBackup)
    }

    func testStoppedServiceExplainsWhyBackupIsUnavailable() {
        let model = makeModel()
        model.connectionState = .stopped
        model.daemonServiceState = .stopped
        model.backupOverdue = true
        let status = BaxterMenuStatus(model: model)

        XCTAssertEqual(Array(status.statusLines.prefix(2)), ["Baxter is stopped", "Backup is unavailable"])
        XCTAssertTrue(status.warnings.isEmpty)
        XCTAssertFalse(status.canRunBackup)
        XCTAssertEqual(status.runBackupDisabledReason, "Start Baxter to run backups.")
        XCTAssertTrue(status.canStartDaemon)
        XCTAssertFalse(status.canStopDaemon)
    }

    func testMissingConfigPointsToSettings() {
        let model = makeModel(hasConfig: false)
        model.connectionState = .stopped
        model.daemonServiceState = .stopped
        let status = BaxterMenuStatus(model: model)

        XCTAssertEqual(Array(status.statusLines.prefix(2)), ["Baxter is not set up", "Backup is not set up"])
        XCTAssertEqual(status.runBackupDisabledReason, "Open Settings to set up your first backup.")
    }

    func testLifecycleFailureIsShownAsWarning() {
        let model = makeModel()
        model.lifecycleMessage = "Start failed: launchctl exited 5"

        XCTAssertEqual(BaxterMenuStatus(model: model).warnings, ["Start failed: launchctl exited 5"])

        model.lifecycleMessage = "Daemon started."
        XCTAssertTrue(BaxterMenuStatus(model: model).warnings.isEmpty)
    }
}
