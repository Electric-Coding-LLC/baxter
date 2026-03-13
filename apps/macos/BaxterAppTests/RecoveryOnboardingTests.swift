import XCTest
@testable import BaxterApp

@MainActor
final class RecoveryOnboardingTests: XCTestCase {
    override func tearDown() {
        RecoveryMockURLProtocol.reset()
        super.tearDown()
    }

    func testExistingBackupValidationDoesNotRequireBackupRoots() {
        let model = BaxterSettingsModel()
        model.backupRoots = []
        model.s3Bucket = "my-backups"
        model.s3Region = "us-west-2"
        model.keychainService = "baxter"
        model.keychainAccount = "default"

        XCTAssertNil(model.existingBackupValidationMessage(passphrase: "secret-passphrase"))
        XCTAssertEqual(model.existingBackupValidationMessage(passphrase: ""), "Enter the encryption passphrase.")
    }

    func testRecoverExistingBackupStoresPassphraseBootstrapsAndReconnects() async throws {
        RecoveryMockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data("{\"state\":\"idle\"}".utf8)
            return (response, data)
        }

        var storedPassphrase: String?
        var storedService: String?
        var storedAccount: String?
        var bootstrapPassphrase: String?
        var startCount = 0

        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeRecoveryMockURLSession(),
            ipcToken: "token-123",
            startLaunchd: {
                startCount += 1
                return "Daemon started."
            },
            stopLaunchd: { "Daemon stopped." },
            storePassphraseInKeychain: { passphrase, service, account in
                storedPassphrase = passphrase
                storedService = service
                storedAccount = account
            },
            runRecoveryBootstrap: { passphrase in
                bootstrapPassphrase = passphrase
                return "recovery bootstrap complete: snapshot=snap-1 entries=12"
            },
            autoStartPolling: false
        )

        let connected = await model.recoverExistingBackup(
            passphrase: "  secret-passphrase  ",
            keychainService: "baxter",
            keychainAccount: "default"
        )

        XCTAssertTrue(connected)
        XCTAssertEqual(storedPassphrase, "secret-passphrase")
        XCTAssertEqual(storedService, "baxter")
        XCTAssertEqual(storedAccount, "default")
        XCTAssertEqual(bootstrapPassphrase, "secret-passphrase")
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(
            model.recoveryMessage,
            "Existing backup connected. recovery bootstrap complete: snapshot=snap-1 entries=12"
        )
        XCTAssertEqual(model.connectionState, .connected)

        let request = try XCTUnwrap(RecoveryMockURLProtocol.requests().first { $0.url?.path == "/v1/status" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Baxter-Token"), "token-123")
    }

    func testRecoverExistingBackupSurfacesBootstrapFailureWithoutRestartingDaemon() async {
        let model = BackupStatusModel(
            baseURL: URL(string: "http://example.test")!,
            urlSession: makeRecoveryMockURLSession(),
            startLaunchd: {
                XCTFail("startLaunchd should not run when bootstrap fails")
                return "Daemon started."
            },
            stopLaunchd: { "Daemon stopped." },
            storePassphraseInKeychain: { _, _, _ in },
            runRecoveryBootstrap: { _ in
                throw NSError(
                    domain: "RecoveryOnboardingTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "wrong passphrase"]
                )
            },
            autoStartPolling: false
        )

        let connected = await model.recoverExistingBackup(
            passphrase: "secret-passphrase",
            keychainService: "baxter",
            keychainAccount: "default"
        )

        XCTAssertFalse(connected)
        XCTAssertEqual(model.recoveryMessage, "Connect existing backup failed: wrong passphrase")
    }
}

private func makeRecoveryMockURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecoveryMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class RecoveryMockURLProtocol: URLProtocol {
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
