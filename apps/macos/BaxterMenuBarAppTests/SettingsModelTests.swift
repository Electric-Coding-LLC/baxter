import XCTest
@testable import BaxterMenuBarApp

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
}

@MainActor
final class BackupStatusModelRestoreTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
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
