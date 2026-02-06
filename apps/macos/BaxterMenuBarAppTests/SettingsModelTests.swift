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
}
