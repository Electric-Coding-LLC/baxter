import AppKit
import Darwin
import Foundation
import SwiftUI

enum DaemonServiceState: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"
}

enum LaunchdController {
    private static var uid: UInt32 { getuid() }

    private static var domainTarget: String { "gui/\(uid)" }

    private static var serviceTarget: String { "\(domainTarget)/\(BaxterRuntime.daemonLabel)" }

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
        do {
            let result = try await runLaunchctlAllowFailure(["print", serviceTarget])
            return result.status == 0 ? .running : .stopped
        } catch {
            return .unknown
        }
    }

    static func hasConfigFile() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    static func install() async throws -> String {
        _ = try await prepareLaunchdInstallAssets()
        _ = try await runLaunchctlAllowFailure(["bootout", serviceTarget])
        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", serviceTarget])
        _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
        return "Daemon installed and started."
    }

    static func start() async throws -> String {
        _ = try await prepareLaunchdInstallAssets()

        let state = await queryState()
        if state == .running {
            _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
            return "Daemon restarted."
        }

        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", serviceTarget])
        _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
        return "Daemon started."
    }

    static func stop() async throws -> String {
        do {
            _ = try await runLaunchctl(["bootout", serviceTarget])
            return "Daemon stopped."
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

    private static func runLaunchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runProcess(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runLaunchctlAllowFailure(_ arguments: [String]) async throws -> CommandResult {
        try await runProcessAllowFailure(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        let result = try await runProcessAllowFailure(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
        if result.status != 0 {
            throw LaunchdError.commandFailed(command: executable, arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    private static func runProcessAllowFailure(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw LaunchdError.executionFailed(error.localizedDescription)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            let status = process.terminationStatus
            return CommandResult(status: status, stdout: stdout, stderr: stderr)
        }.value
    }

    private static func prepareLaunchdInstallAssets() async throws -> String {
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

    static func resolveRepositoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let configured = environment["BAXTER_REPO_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if isRepositoryRoot(url) {
                return url
            }
        }

        for candidate in repositoryRootCandidates(currentDirectoryPath: currentDirectoryPath) {
            if isRepositoryRoot(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func repositoryRootCandidates(currentDirectoryPath: String) -> [URL] {
        var candidates: [URL] = []

        func appendIfNeeded(_ url: URL?) {
            guard let url else {
                return
            }
            let standardized = url.standardizedFileURL
            if !candidates.contains(where: { $0.standardizedFileURL.path == standardized.path }) {
                candidates.append(standardized)
            }
        }

        appendIfNeeded(debugSourceRepositoryRoot())

        var candidate = URL(fileURLWithPath: currentDirectoryPath)
        for _ in 0..<12 {
            appendIfNeeded(candidate)
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }

        return candidates
    }

    private static func debugSourceRepositoryRoot() -> URL? {
        #if DEBUG
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
        #else
        return nil
        #endif
    }

    static func resolveGoBinaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fileManager = FileManager.default

        func executablePath(_ rawPath: String?) -> String? {
            guard let rawPath else {
                return nil
            }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        }

        if let configured = executablePath(environment["BAXTER_GO_BINARY"]) {
            return configured
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                let candidate = String(directory) + "/go"
                if let resolved = executablePath(candidate) {
                    return resolved
                }
            }
        }

        for candidate in [
            "/usr/local/go/bin/go",
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/bin/go",
        ] {
            if let resolved = executablePath(candidate) {
                return resolved
            }
        }

        return nil
    }

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let goMod = url.appendingPathComponent("go.mod").path
        let daemonMain = url.appendingPathComponent("cmd").appendingPathComponent("baxterd").appendingPathComponent("main.go").path
        return fileManager.fileExists(atPath: goMod) && fileManager.fileExists(atPath: daemonMain)
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

    static func helperEnvironmentVariables(homePath: String) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var variables: [String: String] = [
            "HOME": homePath,
            "BAXTER_APP_SUPPORT_DIR": BaxterRuntime.appSupportURL.path,
            "BAXTER_CONFIG_PATH": BaxterRuntime.configURL.path,
        ]
        if let configuredProfile = configuredAWSProfile(), !configuredProfile.isEmpty {
            variables["AWS_PROFILE"] = configuredProfile
            variables["AWS_SDK_LOAD_CONFIG"] = "1"
        }

        for key in [
            "AWS_PROFILE",
            "AWS_SDK_LOAD_CONFIG",
            "AWS_REGION",
            "AWS_DEFAULT_REGION",
            "AWS_SHARED_CREDENTIALS_FILE",
            "AWS_CONFIG_FILE",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
        ] {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                variables[key] = value
            }
        }

        return variables
    }

    private static func configuredAWSProfile() -> String? {
        guard let configText = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        let profile = decodeBaxterConfig(from: configText).s3AWSProfile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? nil : profile
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum LaunchdError: LocalizedError {
    case missingConfig(String)
    case missingPassphrase
    case repoRootNotFound
    case goBinaryNotFound
    case daemonBinaryMissing(String)
    case cliBinaryMissing(String)
    case executionFailed(String)
    case commandFailed(command: String, arguments: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            _ = path
            return "Config not found. Open Settings and save config first."
        case .missingPassphrase:
            return "Passphrase is required."
        case .repoRootNotFound:
            return "Unable to find bundled Baxter helpers or auto-build them from the repo. Set BAXTER_REPO_ROOT for dev builds or install from the packaged app."
        case .goBinaryNotFound:
            return "Go is required to build Baxter helpers for the debug app, but no `go` binary was found. Install Go or set BAXTER_GO_BINARY."
        case .daemonBinaryMissing(let path):
            return "baxterd binary missing at \(path) after install/build."
        case .cliBinaryMissing(let path):
            return "baxter binary missing at \(path) after install/build."
        case .executionFailed(let reason):
            return "Failed to execute command: \(reason)"
        case .commandFailed(let command, let arguments, let stderr):
            let executable = URL(fileURLWithPath: command).lastPathComponent
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(executable) \(arguments.joined(separator: " ")) failed."
            }
            return detail
        }
    }
}
