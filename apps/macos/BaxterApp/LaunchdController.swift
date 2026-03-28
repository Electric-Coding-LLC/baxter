import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

enum DaemonServiceState: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"
}

enum LaunchdController {
    private static var uid: UInt32 { getuid() }

    private static var domainTarget: String { "gui/\(uid)" }

    private static var serviceTargets: [String] {
        var labels = [BaxterRuntime.daemonLabel]
        if BaxterRuntime.shouldUseBundledLaunchAgent(),
           !labels.contains(BaxterRuntime.defaultDaemonLabel) {
            labels.insert(BaxterRuntime.defaultDaemonLabel, at: 0)
        }
        return labels.map { "\(domainTarget)/\($0)" }
    }

    private static var plistPath: String {
        BaxterRuntime.launchAgentURL.path
    }

    private static var appSupportDir: String {
        BaxterRuntime.appSupportURL.path
    }

    private static var daemonBinaryPath: String {
        BaxterRuntime.daemonBinaryURL.path
    }

    private static var cliBinaryPath: String {
        BaxterRuntime.cliBinaryURL.path
    }

    private static var configPath: String {
        BaxterRuntime.configURL.path
    }

    static func queryState() async -> DaemonServiceState {
        for target in serviceTargets {
            do {
                let result = try await runLaunchctlAllowFailure(["print", target])
                if result.status == 0 {
                    return .running
                }
            } catch {
                return .unknown
            }
        }
        return .stopped
    }

    static func hasConfigFile() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    static func install() async throws -> String {
        if try await installBundledAgentIfAvailable() {
            return "Daemon installed and started."
        }
        return try await installLegacyLaunchAgent()
    }

    static func start() async throws -> String {
        let state = await queryState()
        if try await startBundledAgentIfAvailable() {
            return state == .running ? "Daemon restarted." : "Daemon started."
        }
        return try await startLegacyLaunchAgent()
    }

    static func stop() async throws -> String {
        do {
            for target in serviceTargets {
                _ = try await runLaunchctlAllowFailure(["bootout", target])
            }
            let state = await queryState()
            return state == .stopped ? "Daemon stopped." : "Daemon already stopped."
        } catch {
            let state = await queryState()
            if state == .stopped {
                return "Daemon already stopped."
            }
            throw error
        }
    }

    static func runRecoveryBootstrap(passphrase: String) async throws -> String {
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassphrase.isEmpty else {
            throw LaunchdError.missingPassphrase
        }
        guard hasConfigFile() else {
            throw LaunchdError.missingConfig(configPath)
        }

        let binaryPath = try await ensureCLIBinary()
        let result = try await runProcess(
            executable: binaryPath,
            arguments: ["recovery", "bootstrap"],
            environment: helperEnvironmentVariables(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
                .merging(["BAXTER_PASSPHRASE": trimmedPassphrase]) { _, new in new }
        )
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Recovery bootstrap complete." : output
    }

    private static func installLegacyLaunchAgent() async throws -> String {
        _ = try await prepareLegacyLaunchdInstallAssets()
        _ = try await runLaunchctlAllowFailure(["bootout", "\(domainTarget)/\(BaxterRuntime.daemonLabel)"])
        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", "\(domainTarget)/\(BaxterRuntime.daemonLabel)"])
        _ = try await runLaunchctl(["kickstart", "-k", "\(domainTarget)/\(BaxterRuntime.daemonLabel)"])
        return "Daemon installed and started."
    }

    private static func startLegacyLaunchAgent() async throws -> String {
        _ = try await prepareLegacyLaunchdInstallAssets()

        let target = "\(domainTarget)/\(BaxterRuntime.daemonLabel)"
        let state = await queryState()
        if state == .running {
            _ = try await runLaunchctl(["kickstart", "-k", target])
            return "Daemon restarted."
        }

        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", target])
        _ = try await runLaunchctl(["kickstart", "-k", target])
        return "Daemon started."
    }

    private static func installBundledAgentIfAvailable() async throws -> Bool {
        guard BaxterRuntime.shouldUseBundledLaunchAgent() else {
            return false
        }

        _ = try await prepareBundledAppServiceAssets()
        try await unregisterBundledAgentIfNeeded()
        try await removeLegacyLaunchAgentIfPresent()
        try registerBundledAgent()
        _ = try await runLaunchctlAllowFailure(["kickstart", "-k", "\(domainTarget)/\(BaxterRuntime.defaultDaemonLabel)"])
        return true
    }

    private static func startBundledAgentIfAvailable() async throws -> Bool {
        guard BaxterRuntime.shouldUseBundledLaunchAgent() else {
            return false
        }

        _ = try await prepareBundledAppServiceAssets()
        try await removeLegacyLaunchAgentIfPresent()
        try await unregisterBundledAgentIfNeeded()
        try registerBundledAgent()
        _ = try await runLaunchctlAllowFailure(["kickstart", "-k", "\(domainTarget)/\(BaxterRuntime.defaultDaemonLabel)"])
        return true
    }

    private static func prepareLegacyLaunchdInstallAssets() async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configPath) else {
            throw LaunchdError.missingConfig(configPath)
        }

        try fileManager.createDirectory(
            at: URL(fileURLWithPath: daemonBinaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: plistPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let binaryPath = try await ensureDaemonBinary()
        let plistData = try launchAgentPlistData(
            daemonBinaryPath: binaryPath,
            configPath: configPath,
            ipcAddress: BaxterRuntime.ipcAddress,
            homePath: fileManager.homeDirectoryForCurrentUser.path,
            ipcToken: ProcessInfo.processInfo.environment["BAXTER_IPC_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        return binaryPath
    }

    private static func prepareBundledAppServiceAssets() async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configPath) else {
            throw LaunchdError.missingConfig(configPath)
        }
        guard fileManager.fileExists(atPath: BaxterRuntime.bundledLaunchAgentURL.path) else {
            throw LaunchdError.bundledAgentMissing(BaxterRuntime.bundledLaunchAgentURL.path)
        }

        try fileManager.createDirectory(
            at: BaxterRuntime.daemonOutLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        _ = try installBundledHelpersIfAvailable()
        return BaxterRuntime.bundledLaunchAgentURL.path
    }

    private static func ensureDaemonBinary() async throws -> String {
        let fileManager = FileManager.default
        if try installBundledHelpersIfAvailable(),
           fileManager.isExecutableFile(atPath: daemonBinaryPath) {
            return daemonBinaryPath
        }
        if fileManager.isExecutableFile(atPath: daemonBinaryPath) {
            return daemonBinaryPath
        }
        guard let repoRoot = resolveRepositoryRoot() else {
            throw LaunchdError.repoRootNotFound
        }
        guard let goBinaryPath = resolveGoBinaryPath() else {
            throw LaunchdError.goBinaryNotFound
        }

        _ = try await runProcess(
            executable: goBinaryPath,
            arguments: ["build", "-o", daemonBinaryPath, "./cmd/baxterd"],
            currentDirectory: repoRoot
        )
        guard fileManager.isExecutableFile(atPath: daemonBinaryPath) else {
            throw LaunchdError.daemonBinaryMissing(daemonBinaryPath)
        }
        return daemonBinaryPath
    }

    private static func ensureCLIBinary() async throws -> String {
        let fileManager = FileManager.default
        if try installBundledHelpersIfAvailable(),
           fileManager.isExecutableFile(atPath: cliBinaryPath) {
            return cliBinaryPath
        }
        if fileManager.isExecutableFile(atPath: cliBinaryPath) {
            return cliBinaryPath
        }
        guard let repoRoot = resolveRepositoryRoot() else {
            throw LaunchdError.repoRootNotFound
        }
        guard let goBinaryPath = resolveGoBinaryPath() else {
            throw LaunchdError.goBinaryNotFound
        }

        _ = try await runProcess(
            executable: goBinaryPath,
            arguments: ["build", "-o", cliBinaryPath, "./cmd/baxter"],
            currentDirectory: repoRoot
        )
        guard fileManager.isExecutableFile(atPath: cliBinaryPath) else {
            throw LaunchdError.cliBinaryMissing(cliBinaryPath)
        }
        return cliBinaryPath
    }

    private static func installBundledHelpersIfAvailable() throws -> Bool {
        let daemonInstalled = try installBundledBinary(
            named: "baxterd",
            destinationPath: daemonBinaryPath
        )
        let cliInstalled = try installBundledBinary(
            named: "baxter",
            destinationPath: cliBinaryPath
        )
        return daemonInstalled || cliInstalled
    }

    private static func installBundledBinary(named name: String, destinationPath: String) throws -> Bool {
        guard let bundledPath = bundledBinaryPath(named: name) else {
            return false
        }

        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: destinationPath)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        try fileManager.copyItem(atPath: bundledPath, toPath: tempURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        return true
    }

    private static func bundledBinaryPath(named name: String) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        let path = resourceURL.appendingPathComponent("bin").appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func launchAgentPlistData(
        daemonBinaryPath: String,
        configPath: String,
        ipcAddress: String,
        homePath: String,
        ipcToken: String?
    ) throws -> Data {
        var args: [String] = [
            daemonBinaryPath,
            "--config",
            configPath,
            "--ipc-addr",
            ipcAddress,
        ]
        if let token = ipcToken, !token.isEmpty {
            args.append("--ipc-token")
            args.append(token)
        }

        let environmentVariables = helperEnvironmentVariables(homePath: homePath)

        let plist: [String: Any] = [
            "Label": BaxterRuntime.daemonLabel,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": BaxterRuntime.daemonOutLogURL.path,
            "StandardErrorPath": BaxterRuntime.daemonErrLogURL.path,
            "EnvironmentVariables": environmentVariables,
            "AssociatedBundleIdentifiers": Bundle.main.bundleIdentifier ?? "com.electriccoding.BaxterApp",
        ]

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        } catch {
            throw LaunchdError.executionFailed("Failed to generate launchd plist: \(error.localizedDescription)")
        }
    }

    private static func bundledAgentService() -> SMAppService {
        SMAppService.agent(plistName: BaxterRuntime.bundledLaunchAgentPlistName)
    }

    private static func registerBundledAgent() throws {
        do {
            try bundledAgentService().register()
        } catch let error as NSError {
            throw LaunchdError.appServiceRegistrationFailed(messageForAppServiceError(error))
        }
    }

    private static func unregisterBundledAgentIfNeeded() async throws {
        let service = bundledAgentService()
        switch service.status {
        case .enabled, .requiresApproval:
            try await service.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            return
        }
    }

    private static func removeLegacyLaunchAgentIfPresent() async throws {
        let fileManager = FileManager.default
        let target = "\(domainTarget)/\(BaxterRuntime.daemonLabel)"
        _ = try await runLaunchctlAllowFailure(["bootout", target])
        if fileManager.fileExists(atPath: plistPath) {
            try fileManager.removeItem(atPath: plistPath)
        }
    }

    private static func messageForAppServiceError(_ error: NSError) -> String {
        guard error.domain == SMAppServiceErrorDomain else {
            return error.localizedDescription
        }

        switch error.code {
        case kSMErrorInvalidSignature:
            return "Bundled Baxter background helper requires a signed app build."
        case kSMErrorJobPlistNotFound, kSMErrorToolNotValid:
            return "Bundled Baxter background helper assets are incomplete. Reinstall the packaged app."
        case kSMErrorLaunchDeniedByUser:
            return "macOS denied the Baxter background item. Re-enable it in System Settings > Login Items."
        default:
            return error.localizedDescription
        }
    }
}
