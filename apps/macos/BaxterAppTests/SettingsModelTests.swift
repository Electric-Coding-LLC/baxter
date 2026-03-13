import XCTest
import Darwin
@testable import BaxterApp

@MainActor
final class SettingsModelTests: XCTestCase {
    func testInvalidBackupRootBlocksSave() throws {
        let model = BaxterSettingsModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("not-a-directory.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        model.backupRoots = [fileURL.path]
        model.s3Bucket = ""
        model.s3Region = ""
        model.s3Endpoint = ""
        model.keychainService = "baxter"
        model.keychainAccount = "default"

        model.validateDraft()

        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.backupRootWarning(for: fileURL.path), "Path is not a folder.")
        XCTAssertEqual(model.validationMessage(for: .backupRoots), "Fix invalid backup folders before saving.")
    }

    func testValidBackupRootAllowsSave() throws {
        let model = BaxterSettingsModel()
        let dirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        model.backupRoots = [dirURL.path]
        model.s3Bucket = ""
        model.s3Region = ""
        model.s3Endpoint = ""
        model.keychainService = "baxter"
        model.keychainAccount = "default"

        model.validateDraft()

        XCTAssertTrue(model.canSave)
        XCTAssertNil(model.backupRootWarning(for: dirURL.path))
        XCTAssertNil(model.validationMessage(for: .backupRoots))
    }

    func testS3EndpointValidation() {
        let model = BaxterSettingsModel()

        model.backupRoots = []
        model.s3Bucket = "my-backups"
        model.s3Region = "us-west-2"
        model.s3Endpoint = "not-a-url"

        model.validateDraft()
        XCTAssertEqual(model.validationMessage(for: .s3Endpoint), "Endpoint must be a valid http(s) URL.")

        model.s3Endpoint = "https://s3.amazonaws.com"
        model.validateDraft()
        XCTAssertNil(model.validationMessage(for: .s3Endpoint))
    }

    func testS3ModeHintChangesByBucketState() {
        let model = BaxterSettingsModel()

        model.s3Bucket = ""
        XCTAssertTrue(model.s3ModeHint.contains("Local mode"))

        model.s3Bucket = "my-backups"
        XCTAssertTrue(model.s3ModeHint.contains("S3 mode"))
    }

    func testShouldOfferApplyNowWhenSaveSucceededAndDaemonRunning() {
        let model = BaxterSettingsModel()
        model.errorMessage = nil

        XCTAssertTrue(model.shouldOfferApplyNow(daemonState: .running))
        XCTAssertFalse(model.shouldOfferApplyNow(daemonState: .stopped))
        XCTAssertFalse(model.shouldOfferApplyNow(daemonState: .unknown))
    }

    func testShouldNotOfferApplyNowWhenSaveFailed() {
        let model = BaxterSettingsModel()
        model.errorMessage = "save failed"

        XCTAssertFalse(model.shouldOfferApplyNow(daemonState: .running))
    }

    func testDailyScheduleRequiresValidTime() {
        let model = BaxterSettingsModel()
        model.backupRoots = []
        model.schedule = .daily
        model.dailyTime = "9:0"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .dailyTime), "Daily time must be HH:MM (24-hour).")
        XCTAssertFalse(model.canSave)
    }

    func testWeeklyScheduleRequiresValidTime() {
        let model = BaxterSettingsModel()
        model.backupRoots = []
        model.schedule = .weekly
        model.weeklyTime = "24:00"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .weeklyTime), "Weekly time must be HH:MM (24-hour).")
        XCTAssertFalse(model.canSave)
    }

    func testRelativeBackupRootShowsAbsolutePathWarning() {
        let model = BaxterSettingsModel()
        model.backupRoots = ["relative/path"]

        model.validateDraft()

        XCTAssertEqual(model.backupRootWarning(for: "relative/path"), "Folder path must be absolute.")
        XCTAssertEqual(model.validationMessage(for: .backupRoots), "Fix invalid backup folders before saving.")
    }

    func testExcludePathsMustBeAbsolute() {
        let model = BaxterSettingsModel()
        model.excludePathsText = "relative/path\n/Users/me/Documents/Cache"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .excludePaths), "Exclude paths must be absolute (one per line).")
        XCTAssertFalse(model.canSave)
    }

    func testExcludeGlobPatternValidation() {
        let model = BaxterSettingsModel()
        model.excludeGlobsText = "["

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .excludeGlobs), "Exclude glob contains an invalid pattern.")
        XCTAssertFalse(model.canSave)
    }

    func testExcludeGlobPatternValidationRejectsUnmatchedClosingBracket() {
        let model = BaxterSettingsModel()
        model.excludeGlobsText = "]"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .excludeGlobs), "Exclude glob contains an invalid pattern.")
        XCTAssertFalse(model.canSave)
    }

    func testDecodeConfigParsesMultiLineExcludeGlobsWithBracketClass() {
        let toml = """
        backup_roots = [
          "/Users/me/Documents",
        ]
        exclude_paths = []
        exclude_globs = [
          "[0-9]*.log",
          "*.tmp",
        ]
        schedule = "manual"

        [s3]
        endpoint = ""
        region = ""
        bucket = ""
        prefix = "baxter/"
        aws_profile = "baxter"

        [encryption]
        keychain_service = "baxter"
        keychain_account = "default"

        [verify]
        schedule = "manual"
        daily_time = "09:00"
        weekly_day = "sunday"
        weekly_time = "09:00"
        prefix = ""
        limit = 0
        sample = 0
        """

        let config = decodeBaxterConfig(from: toml)
        XCTAssertEqual(config.excludeGlobs, ["[0-9]*.log", "*.tmp"])
        XCTAssertEqual(config.s3AWSProfile, "baxter")
    }

    func testVerifyDailyScheduleRequiresValidTime() {
        let model = BaxterSettingsModel()
        model.verifySchedule = .daily
        model.verifyDailyTime = "9:0"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .verifyDailyTime), "Verify daily time must be HH:MM (24-hour).")
        XCTAssertFalse(model.canSave)
    }

    func testVerifyLimitMustBeNonNegativeInteger() {
        let model = BaxterSettingsModel()
        model.verifyLimit = "-1"

        model.validateDraft()

        XCTAssertEqual(model.validationMessage(for: .verifyLimit), "Verify limit must be a non-negative integer.")
        XCTAssertFalse(model.canSave)
    }

    func testSetStorageModeLocalClearsS3Coordinates() {
        let model = BaxterSettingsModel()
        model.s3Endpoint = "https://s3.amazonaws.com"
        model.s3Region = "us-west-2"
        model.s3Bucket = "bucket"

        model.setStorageMode(.local)

        XCTAssertEqual(model.s3Endpoint, "")
        XCTAssertEqual(model.s3Region, "")
        XCTAssertEqual(model.s3Bucket, "")
        XCTAssertEqual(model.storageMode(), .local)
    }

    func testFirstRunValidationMessageRequiresBackupRoot() {
        let model = BaxterSettingsModel()
        model.backupRoots = []

        XCTAssertEqual(model.firstRunValidationMessage(), "Select at least one backup folder.")
    }

    func testFirstRunValidationMessageRequiresKeySource() {
        let model = BaxterSettingsModel()
        _ = setenv("BAXTER_PASSPHRASE", "", 1)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        model.backupRoots = [tempDir.path]
        model.keychainService = ""
        model.keychainAccount = ""

        XCTAssertEqual(model.firstRunValidationMessage(), "Configure BAXTER_PASSPHRASE or keychain service/account.")
    }
}

@MainActor
final class BackupStatusModelRestoreTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testFetchSnapshotsLoadsSummariesAndIncludesIPCAuthHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("""
            {"snapshots":[
              {"id":"snap-2","created_at":"2026-02-24T10:00:00Z","entries":12},
              {"id":"snap-1","created_at":"2026-02-23T10:00:00Z","entries":10}
            ]}
            """.utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            ipcToken: "token-123",
            autoStartPolling: false
        )
        model.selectedSnapshot = "snap-2"

        model.fetchSnapshots(limit: 42)
        await waitUntil("snapshot fetch completion") { model.snapshots.count == 2 }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/snapshots" }
        )
        let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
        XCTAssertEqual(model.snapshots.first?.id, "snap-2")
        XCTAssertEqual(model.selectedSnapshot, "snap-2")
        XCTAssertEqual(model.selectedSnapshotRequestValue, "snap-2")
        XCTAssertEqual(model.selectedSnapshotSummary?.entries, 12)
    }

    func testFetchSnapshotsResetsMissingSelectionToLatest() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("""
            {"snapshots":[
              {"id":"snap-9","created_at":"2026-02-24T10:00:00Z","entries":9}
            ]}
            """.utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )
        model.selectedSnapshot = "does-not-exist"

        model.fetchSnapshots()
        await waitUntil("snapshot fetch fallback") { model.snapshotsMessage != nil }

        XCTAssertEqual(model.selectedSnapshot, BackupStatusModel.latestSnapshotSelection)
        XCTAssertEqual(model.selectedSnapshotRequestValue, "")
        XCTAssertNil(model.selectedSnapshotSummary)
        XCTAssertEqual(model.snapshots.count, 1)
    }

    func testFetchRestoreListIncludesSnapshotQueryItem() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"paths\":[]}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            ipcToken: "token-123",
            autoStartPolling: false
        )

        model.fetchRestoreList(prefix: "docs", contains: "notes", snapshot: "snap-123")
        await waitUntil("restore list completion") { model.restorePreviewMessage != nil }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/restore/list" }
        )
        let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "prefix" })?.value, "docs")
        XCTAssertEqual(queryItems.first(where: { $0.name == "contains" })?.value, "notes")
        XCTAssertEqual(queryItems.first(where: { $0.name == "snapshot" })?.value, "snap-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
    }

    func testFetchRestorePathsChildrenModeIncludesChildrenQueryItem() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"paths\":[\"/Users/me/actions-runner/_work/\"]}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )

        let paths = try await model.fetchRestorePaths(
            prefix: "/Users/me/actions-runner",
            contains: "",
            snapshot: "snap-children",
            childrenOnly: true
        )
        XCTAssertEqual(paths, ["/Users/me/actions-runner/_work/"])

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/restore/list" }
        )
        let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "prefix" })?.value, "/Users/me/actions-runner")
        XCTAssertEqual(queryItems.first(where: { $0.name == "snapshot" })?.value, "snap-children")
        XCTAssertEqual(queryItems.first(where: { $0.name == "children" })?.value, "1")
    }

    func testPreviewRestoreSendsSnapshotInRequestBody() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"source_path\":\"a.txt\",\"target_path\":\"/tmp/a.txt\",\"overwrite\":false}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )

        model.previewRestore(path: "a.txt", toDir: "", overwrite: false, snapshot: "snap-456")
        await waitUntil("restore dry-run completion") { model.restorePreviewMessage?.contains("Dry-run:") == true }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/restore/dry-run" }
        )
        let body = try XCTUnwrap(requestBodyData(request))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(payload["path"] as? String, "a.txt")
        XCTAssertEqual(payload["overwrite"] as? Bool, false)
        XCTAssertEqual(payload["snapshot"] as? String, "snap-456")
        XCTAssertNil(payload["to_dir"])
        XCTAssertNil(payload["verify_only"])
    }

    func testRunRestoreFormatsDaemonErrorWithCode() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"code\":\"restore_conflict\",\"message\":\"restore already running\"}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )

        model.runRestore(path: "a.txt", toDir: "/tmp", overwrite: true, verifyOnly: true, snapshot: "snap-789")
        await waitUntil("restore run error") { model.restorePreviewMessage != nil }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/restore/run" }
        )
        let body = try XCTUnwrap(requestBodyData(request))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(payload["path"] as? String, "a.txt")
        XCTAssertEqual(payload["to_dir"] as? String, "/tmp")
        XCTAssertEqual(payload["overwrite"] as? Bool, true)
        XCTAssertEqual(payload["verify_only"] as? Bool, true)
        XCTAssertEqual(payload["snapshot"] as? String, "snap-789")
        XCTAssertEqual(model.restorePreviewMessage, "Restore failed [restore_conflict]: restore already running")
    }

    func testRunRestoreFormatsTransientStorageErrorWithGuidance() async throws {
        MockURLProtocol.requestHandler = { _ in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: URL(string: "http://example.test/v1/restore/run")!, statusCode: 503, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"code\":\"restore_storage_transient\",\"message\":\"transient read failure\"}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )

        model.runRestore(path: "a.txt", toDir: "/tmp", overwrite: false, verifyOnly: false, snapshot: "")
        await waitUntil("restore transient error guidance") { model.restorePreviewMessage != nil }

        XCTAssertEqual(
            model.restorePreviewMessage,
            "Restore failed [restore_storage_transient]: Temporary storage error while reading backup data. Retry in a moment."
        )
    }

    func testRunRestoreFormatsTargetExistsErrorWithGuidance() async throws {
        MockURLProtocol.requestHandler = { _ in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: URL(string: "http://example.test/v1/restore/run")!, statusCode: 400, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"code\":\"target_exists\",\"message\":\"target already exists\"}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            autoStartPolling: false
        )

        model.runRestore(path: "a.txt", toDir: "/tmp", overwrite: false, verifyOnly: false, snapshot: "")
        await waitUntil("restore target exists guidance") { model.restorePreviewMessage != nil }

        XCTAssertEqual(
            model.restorePreviewMessage,
            "Restore failed [target_exists]: The destination file already exists. Enable overwrite or choose a different destination."
        )
    }

    func testRunRestoreIncludesIPCAuthHeaderWhenTokenConfigured() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"source_path\":\"a.txt\",\"target_path\":\"/tmp/a.txt\",\"verified\":true,\"wrote\":false}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            ipcToken: "token-123",
            autoStartPolling: false
        )

        model.runRestore(path: "a.txt", toDir: "/tmp", overwrite: false, verifyOnly: true, snapshot: "")
        await waitUntil("restore run success") { model.restorePreviewMessage?.contains("verify-only") == true }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/restore/run" }
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
    }

    func testRunVerifyIncludesIPCAuthHeaderWhenTokenConfigured() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            ipcToken: "token-123",
            autoStartPolling: false
        )

        model.runVerify()
        await waitUntil("verify run request") {
            MockURLProtocol.requests().contains(where: { $0.url?.path == "/v1/verify/run" })
        }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/verify/run" }
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
    }

    func testRefreshStatusIncludesIPCAuthHeaderWhenTokenConfigured() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"state\":\"idle\"}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            ipcToken: "token-123",
            autoStartPolling: false
        )

        model.refreshStatus()
        await waitUntil("status request") {
            MockURLProtocol.requests().contains(where: { $0.url?.path == "/v1/status" })
        }

        let request = try XCTUnwrap(
            MockURLProtocol.requests().first { $0.url?.path == "/v1/status" }
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
    }

    func testRefreshStatusTreatsInitialIPCFailureAsConnecting() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            queryLaunchdState: { .running },
            nowProvider: { now },
            autoStartPolling: false
        )

        model.refreshStatus()
        await waitUntil("initial IPC startup state") { model.connectionState == .connecting }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.state, .idle)
    }

    func testRefreshStatusEscalatesToUnavailableAfterRepeatedFailures() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            queryLaunchdState: { .running },
            nowProvider: { now },
            autoStartPolling: false
        )

        model.refreshStatus()
        await waitUntil("first IPC failure") {
            MockURLProtocol.requests().filter { $0.url?.path == "/v1/status" }.count >= 1
                && model.connectionState == .connecting
        }
        XCTAssertEqual(model.connectionState, .connecting)

        now = now.addingTimeInterval(35)
        model.refreshStatus()
        await waitUntil("escalated IPC failure") {
            MockURLProtocol.requests().filter { $0.url?.path == "/v1/status" }.count >= 2
                && model.connectionState == .unavailable
        }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.state, .idle)
    }

    func testRefreshStatusSendsFailureNotificationOncePerTransition() async throws {
        let notifications = MockNotificationDispatcher()
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"state\":\"failed\",\"last_error\":\"backup exploded\"}".utf8)
            return (response, data)
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            notificationDispatcher: notifications,
            autoStartPolling: false
        )

        XCTAssertTrue(notifications.authorizationRequested)
        model.refreshStatus()
        await waitUntil("first failure notification") { notifications.notifications.count == 1 }
        model.refreshStatus()
        await waitUntil("second status request") {
            MockURLProtocol.requests().filter { $0.url?.path == "/v1/status" }.count >= 2
        }

        XCTAssertEqual(notifications.notifications.count, 1)
        XCTAssertEqual(notifications.notifications.first?.0, "Baxter backup failed")
    }

    func testRefreshStatusSendsSuccessNotificationWhenEnabled() async throws {
        let notifications = MockNotificationDispatcher()
        var statusCallCount = 0
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            defer { statusCallCount += 1 }
            if statusCallCount == 0 {
                return (response, Data("{\"state\":\"running\"}".utf8))
            }
            return (response, Data("{\"state\":\"idle\",\"last_backup_at\":\"2026-02-24T12:00:00Z\"}".utf8))
        }

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeMockURLSession(),
            notificationDispatcher: notifications,
            autoStartPolling: false
        )
        model.notifyOnSuccess = true

        model.refreshStatus()
        await waitUntil("running state refresh") { model.state == .running }
        model.refreshStatus()
        await waitUntil("success notification") {
            notifications.notifications.contains(where: { $0.0 == "Baxter backup completed" })
        }

        XCTAssertTrue(notifications.notifications.contains(where: { $0.0 == "Baxter backup completed" }))
    }
}

final class DiagnosticsBundleBuilderTests: XCTestCase {
    func testMakeBundleRedactsSensitiveConfigAndLogValues() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml")
        try """
        [encryption]
        keychain_service = "baxter"
        keychain_account = "default"
        passphrase = "super-secret-passphrase"
        ipc_token = "ci-smoke-token"
        """.write(to: configPath, atomically: true, encoding: .utf8)

        let outLogPath = tempDir.appendingPathComponent("baxterd.out.log")
        try "X-Baxter-Token: inline-token\nnormal-line".write(to: outLogPath, atomically: true, encoding: .utf8)
        let errLogPath = tempDir.appendingPathComponent("baxterd.err.log")
        try "BAXTER_PASSPHRASE=from-env-secret".write(to: errLogPath, atomically: true, encoding: .utf8)

        let bundle = DiagnosticsBundleBuilder.makeBundle(
            configPath: configPath.path,
            daemonState: "running",
            ipcReachable: true,
            backupState: "Idle",
            verifyState: "Idle",
            lastBackupError: "authorization: bearer secret-token",
            lastVerifyError: nil,
            lastRestoreError: nil,
            daemonOutLogPath: outLogPath.path,
            daemonErrLogPath: errLogPath.path
        )

        XCTAssertFalse(bundle.contents.contains("super-secret-passphrase"))
        XCTAssertFalse(bundle.contents.contains("ci-smoke-token"))
        XCTAssertFalse(bundle.contents.contains("inline-token"))
        XCTAssertFalse(bundle.contents.contains("from-env-secret"))
        XCTAssertFalse(bundle.contents.contains("secret-token"))
        XCTAssertTrue(bundle.contents.contains("[REDACTED]"))
    }

    func testMakeBundleIncludesRecentLogTail() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml")
        try "schedule = \"manual\"".write(to: configPath, atomically: true, encoding: .utf8)

        let outLogPath = tempDir.appendingPathComponent("baxterd.out.log")
        let lines = (1...140).map { String(format: "out-line-%04d", $0) }.joined(separator: "\n")
        try lines.write(to: outLogPath, atomically: true, encoding: .utf8)

        let errLogPath = tempDir.appendingPathComponent("baxterd.err.log")
        try "err-line-1\nerr-line-2".write(to: errLogPath, atomically: true, encoding: .utf8)

        let bundle = DiagnosticsBundleBuilder.makeBundle(
            configPath: configPath.path,
            daemonState: "running",
            ipcReachable: true,
            backupState: "Idle",
            verifyState: "Idle",
            lastBackupError: nil,
            lastVerifyError: nil,
            lastRestoreError: nil,
            daemonOutLogPath: outLogPath.path,
            daemonErrLogPath: errLogPath.path
        )

        XCTAssertFalse(bundle.contents.contains("out-line-0001"))
        XCTAssertTrue(bundle.contents.contains("out-line-0140"))
        XCTAssertTrue(bundle.contents.contains("err-line-2"))
    }
}

final class RestoreBrowserIndexTests: XCTestCase {
    func testBuildRestoreBrowserIndexBuildsFolderTree() {
        let index = buildRestoreBrowserIndex(
            paths: [
                "/docs/notes/todo.txt",
                "/docs/notes/ideas.md",
                "/docs/photo.jpg",
                "/music/song.mp3",
            ],
            maxPaths: 2_000
        )

        XCTAssertEqual(index.rootNodes.map(\.path), ["/docs", "/music"])
        XCTAssertEqual(index.isDirectoryByPath["/docs"], true)
        XCTAssertEqual(index.isDirectoryByPath["/docs/notes"], true)
        XCTAssertEqual(index.isDirectoryByPath["/docs/photo.jpg"], false)
        XCTAssertEqual(index.isDirectoryByPath["/music/song.mp3"], false)
        XCTAssertFalse(index.didTruncate)
    }

    func testMergeRestoreBrowserIndexAddsLoadedChildrenToExistingTree() {
        let initial = buildRestoreBrowserIndex(
            paths: [
                "/docs/photo.jpg",
                "/music/song.mp3",
            ],
            maxPaths: 2_000
        )

        let merged = mergeRestoreBrowserIndex(
            initial,
            paths: [
                "/docs/notes/todo.txt",
                "/docs/notes/ideas.md",
            ]
        )

        XCTAssertEqual(merged.rootNodes.map(\.path), ["/docs", "/music"])
        XCTAssertEqual(
            flattenRestoreBrowserNodePaths(merged.rootNodes),
            [
                "/docs",
                "/docs/notes",
                "/docs/notes/ideas.md",
                "/docs/notes/todo.txt",
                "/docs/photo.jpg",
                "/music",
                "/music/song.mp3",
            ]
        )
        XCTAssertEqual(merged.isDirectoryByPath["/docs/notes"], true)
        XCTAssertEqual(merged.isDirectoryByPath["/docs/photo.jpg"], false)
    }

    func testMergeRestoreBrowserIndexPromotesExistingLeafToDirectoryWhenDescendantsArrive() {
        let initial = buildRestoreBrowserIndex(
            paths: ["/docs"],
            maxPaths: 2_000
        )

        let merged = mergeRestoreBrowserIndex(
            initial,
            paths: ["/docs/notes/todo.txt"]
        )

        XCTAssertEqual(initial.isDirectoryByPath["/docs"], false)
        XCTAssertEqual(merged.isDirectoryByPath["/docs"], true)
        XCTAssertEqual(
            flattenRestoreBrowserNodePaths(merged.rootNodes),
            ["/docs", "/docs/notes", "/docs/notes/todo.txt"]
        )
    }

    func testFilterRestoreBrowserNodesKeepsAncestorFolders() {
        let index = buildRestoreBrowserIndex(
            paths: [
                "/docs/notes/todo.txt",
                "/docs/notes/ideas.md",
                "/docs/photo.jpg",
            ],
            maxPaths: 2_000
        )

        let filtered = filterRestoreBrowserNodes(index.rootNodes, query: "todo")
        XCTAssertEqual(
            flattenRestoreBrowserNodePaths(filtered),
            ["/docs", "/docs/notes", "/docs/notes/todo.txt"]
        )
    }

    func testFilterRestoreBrowserNodesIncludesDescendantsWhenFolderMatches() {
        let index = buildRestoreBrowserIndex(
            paths: [
                "/docs/notes/todo.txt",
                "/docs/notes/ideas.md",
                "/docs/photo.jpg",
            ],
            maxPaths: 2_000
        )

        let filtered = filterRestoreBrowserNodes(index.rootNodes, query: "docs")
        XCTAssertEqual(
            flattenRestoreBrowserNodePaths(filtered),
            ["/docs", "/docs/notes", "/docs/notes/ideas.md", "/docs/notes/todo.txt", "/docs/photo.jpg"]
        )
    }

    func testBuildRestoreBrowserIndexTruncatesByMaxPaths() {
        let index = buildRestoreBrowserIndex(
            paths: [
                "gamma.txt",
                "alpha.txt",
                "beta.txt",
            ],
            maxPaths: 2
        )

        XCTAssertTrue(index.didTruncate)
        XCTAssertEqual(flattenRestoreBrowserNodePaths(index.rootNodes), ["alpha.txt", "beta.txt"])
    }

    func testRestorePathHelpersHandleAbsoluteAndRelativePaths() {
        XCTAssertEqual(restorePathName("/docs/notes/todo.txt"), "todo.txt")
        XCTAssertEqual(restorePathName("/"), "/")
        XCTAssertEqual(restorePathName("docs/notes.txt"), "notes.txt")

        XCTAssertEqual(restoreParentPath("/docs/notes/todo.txt"), "/docs/notes")
        XCTAssertEqual(restoreParentPath("/docs"), "/")
        XCTAssertEqual(restoreParentPath("docs/notes.txt"), "docs")
        XCTAssertEqual(restoreParentPath("notes.txt"), "/")
    }
}

final class RestoreBrowserLoadCoordinatorTests: XCTestCase {
    func testStartLoadMarksDirectoryLoadingAndCompleteLoadMarksItLoaded() throws {
        var coordinator = RestoreBrowserLoadCoordinator()
        let query = RestoreBrowserQuery(rootPrefix: "/docs", contains: "todo", snapshot: "snap-1")

        coordinator.reset(for: query)
        let token = try XCTUnwrap(
            coordinator.startLoad(directoryKey: "/docs", query: query)
        )

        XCTAssertEqual(coordinator.loadingDirectoryKeys, ["/docs"])
        XCTAssertTrue(coordinator.completeLoad(token, success: true))
        XCTAssertEqual(coordinator.loadedDirectoryKeys, ["/docs"])
        XCTAssertTrue(coordinator.loadingDirectoryKeys.isEmpty)
    }

    func testResetRejectsStaleLoadCompletion() throws {
        var coordinator = RestoreBrowserLoadCoordinator()
        let firstQuery = RestoreBrowserQuery(rootPrefix: "/docs", contains: "", snapshot: "")
        let secondQuery = RestoreBrowserQuery(rootPrefix: "/music", contains: "", snapshot: "")

        coordinator.reset(for: firstQuery)
        let staleToken = try XCTUnwrap(
            coordinator.startLoad(directoryKey: "/docs", query: firstQuery)
        )

        coordinator.reset(for: secondQuery)

        XCTAssertFalse(coordinator.completeLoad(staleToken, success: true))
        XCTAssertTrue(coordinator.loadedDirectoryKeys.isEmpty)
        XCTAssertTrue(coordinator.loadingDirectoryKeys.isEmpty)
    }

    func testStartLoadSkipsDuplicateAndOutOfQueryRequests() throws {
        var coordinator = RestoreBrowserLoadCoordinator()
        let activeQuery = RestoreBrowserQuery(rootPrefix: "/docs", contains: "todo", snapshot: "snap-1")
        let otherQuery = RestoreBrowserQuery(rootPrefix: "/docs", contains: "ideas", snapshot: "snap-1")

        coordinator.reset(for: activeQuery)

        let firstToken = try XCTUnwrap(
            coordinator.startLoad(directoryKey: "/docs", query: activeQuery)
        )
        XCTAssertNil(coordinator.startLoad(directoryKey: "/docs", query: activeQuery))
        XCTAssertNil(coordinator.startLoad(directoryKey: "/docs", query: otherQuery))

        XCTAssertTrue(coordinator.completeLoad(firstToken, success: true))
        XCTAssertNil(coordinator.startLoad(directoryKey: "/docs", query: activeQuery))
    }
}

private func makeMockURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func waitUntil(_ label: String, timeout: TimeInterval = 1.5, condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for \(label)")
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        if readCount <= 0 {
            break
        }
        data.append(buffer, count: readCount)
    }

    return data
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()
    private static var observedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        Self.lock.lock()
        Self.observedRequests.append(request)
        handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requestHandler = nil
        observedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        let value = observedRequests
        lock.unlock()
        return value
    }
}

private final class MockNotificationDispatcher: NotificationDispatching {
    private(set) var authorizationRequested = false
    private(set) var notifications: [(String, String)] = []

    func requestAuthorizationIfNeeded() {
        authorizationRequested = true
    }

    func sendNotification(title: String, body: String) {
        notifications.append((title, body))
    }
}
