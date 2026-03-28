import Foundation
import ServiceManagement

extension LaunchdController {
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

    static func runLaunchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runProcess(executable: "/bin/launchctl", arguments: arguments)
    }

    static func runLaunchctlAllowFailure(_ arguments: [String]) async throws -> CommandResult {
        try await runProcessAllowFailure(executable: "/bin/launchctl", arguments: arguments)
    }

    static func runProcess(
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

    static func runProcessAllowFailure(
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

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let goMod = url.appendingPathComponent("go.mod").path
        let daemonMain = url.appendingPathComponent("cmd").appendingPathComponent("baxterd").appendingPathComponent("main.go").path
        return fileManager.fileExists(atPath: goMod) && fileManager.fileExists(atPath: daemonMain)
    }

    private static func configuredAWSProfile() -> String? {
        guard let configText = try? String(contentsOfFile: BaxterRuntime.configURL.path, encoding: .utf8) else {
            return nil
        }
        let profile = decodeBaxterConfig(from: configText).s3AWSProfile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? nil : profile
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum LaunchdError: LocalizedError {
    case missingConfig(String)
    case missingPassphrase
    case repoRootNotFound
    case goBinaryNotFound
    case daemonBinaryMissing(String)
    case cliBinaryMissing(String)
    case bundledAgentMissing(String)
    case appServiceRegistrationFailed(String)
    case executionFailed(String)
    case commandFailed(command: String, arguments: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
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
        case .bundledAgentMissing(let path):
            return "Bundled Baxter launch agent is missing at \(path). Reinstall the packaged app."
        case .appServiceRegistrationFailed(let message):
            return message
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
