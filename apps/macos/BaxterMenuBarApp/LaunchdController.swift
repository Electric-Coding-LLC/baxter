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

    static func queryState() async -> DaemonServiceState {
        do {
            let result = try await runLaunchctlAllowFailure(["print", serviceTarget])
            return result.status == 0 ? .running : .stopped
        } catch {
            return .unknown
        }
    }

    static func start() async throws -> String {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw LaunchdError.missingPlist(plistPath)
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

    private static func runProcess(executable: String, arguments: [String]) async throws -> CommandResult {
        let result = try await runProcessAllowFailure(executable: executable, arguments: arguments)
        if result.status != 0 {
            throw LaunchdError.commandFailed(command: executable, arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    private static func runProcessAllowFailure(executable: String, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum LaunchdError: LocalizedError {
    case missingPlist(String)
    case executionFailed(String)
    case commandFailed(command: String, arguments: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingPlist(let path):
            return "LaunchAgent plist not found at \(path). Run scripts/install-launchd.sh once."
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
