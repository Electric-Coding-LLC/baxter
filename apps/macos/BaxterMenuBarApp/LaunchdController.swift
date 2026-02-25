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
    private static let label = "com.electriccoding.baxterd"
    private static let ipcAddress = "127.0.0.1:41820"

    private static var uid: UInt32 { getuid() }

    private static var domainTarget: String { "gui/\(uid)" }

    private static var serviceTarget: String { "\(domainTarget)/\(label)" }

    private static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
            .path
    }

    private static var appSupportDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("baxter")
            .path
    }

    private static var daemonBinaryPath: String {
        URL(fileURLWithPath: appSupportDir)
            .appendingPathComponent("bin")
            .appendingPathComponent("baxterd")
            .path
    }

    private static var configPath: String {
        URL(fileURLWithPath: appSupportDir)
            .appendingPathComponent("config.toml")
            .path
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
            ipcAddress: ipcAddress,
            homePath: fileManager.homeDirectoryForCurrentUser.path,
            ipcToken: ProcessInfo.processInfo.environment["BAXTER_IPC_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

        _ = try await runLaunchctlAllowFailure(["bootout", serviceTarget])
        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", serviceTarget])
        _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
        return "Daemon installed and started."
    }

    static func start() async throws -> String {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return try await install()
        }

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

    private static func runLaunchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runProcess(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runLaunchctlAllowFailure(_ arguments: [String]) async throws -> CommandResult {
        try await runProcessAllowFailure(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runProcess(executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> CommandResult {
        let result = try await runProcessAllowFailure(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        if result.status != 0 {
            throw LaunchdError.commandFailed(command: executable, arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    private static func runProcessAllowFailure(executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
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

    private static func ensureDaemonBinary() async throws -> String {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: daemonBinaryPath) {
            return daemonBinaryPath
        }
        guard let repoRoot = resolveRepositoryRoot() else {
            throw LaunchdError.repoRootNotFound
        }

        _ = try await runProcess(
            executable: "/usr/bin/env",
            arguments: ["go", "build", "-o", daemonBinaryPath, "./cmd/baxterd"],
            currentDirectory: repoRoot
        )
        guard fileManager.isExecutableFile(atPath: daemonBinaryPath) else {
            throw LaunchdError.daemonBinaryMissing(daemonBinaryPath)
        }
        return daemonBinaryPath
    }

    private static func resolveRepositoryRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["BAXTER_REPO_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if isRepositoryRoot(url) {
                return url
            }
        }

        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            if isRepositoryRoot(candidate) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
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

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "\(homePath)/Library/Logs/baxterd.out.log",
            "StandardErrorPath": "\(homePath)/Library/Logs/baxterd.err.log",
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
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum LaunchdError: LocalizedError {
    case missingConfig(String)
    case repoRootNotFound
    case daemonBinaryMissing(String)
    case executionFailed(String)
    case commandFailed(command: String, arguments: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            return "Config not found at \(path). Open Settings and save config first."
        case .repoRootNotFound:
            return "Unable to auto-build baxterd. Set BAXTER_REPO_ROOT to your repo path or install launchd manually."
        case .daemonBinaryMissing(let path):
            return "baxterd binary missing at \(path) after build."
        case .executionFailed(let reason):
            return "Failed to execute launchctl: \(reason)"
        case .commandFailed(_, let arguments, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "launchctl \(arguments.joined(separator: " ")) failed."
            }
            return detail
        }
    }
}
