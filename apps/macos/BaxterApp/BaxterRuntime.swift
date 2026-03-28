import Foundation

enum BaxterRuntime {
    #if DEBUG
    static let defaultStateDirectoryName = "baxter-dev"
    static let defaultDaemonLabel = "com.electriccoding.baxterd.dev"
    static let defaultIPCAddress = "127.0.0.1:43129"
    static let defaultLogStem = "baxterd-dev"
    #else
    static let defaultStateDirectoryName = "baxter"
    static let defaultDaemonLabel = "com.electriccoding.baxterd"
    static let defaultIPCAddress = "127.0.0.1:41820"
    static let defaultLogStem = "baxterd"
    #endif

    private static let appServiceBlockingEnvironmentVariables = [
        "BAXTER_APP_SUPPORT_DIR",
        "BAXTER_CONFIG_PATH",
        "BAXTER_LAUNCHD_LABEL",
        "BAXTER_IPC_ADDR",
        "BAXTER_IPC_TOKEN",
    ]

    private static func trimmedEnvironmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var appSupportURL: URL {
        if let path = trimmedEnvironmentValue("BAXTER_APP_SUPPORT_DIR") {
            return URL(fileURLWithPath: path)
        }
        return homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(defaultStateDirectoryName)
    }

    static var configURL: URL {
        if let path = trimmedEnvironmentValue("BAXTER_CONFIG_PATH") {
            return URL(fileURLWithPath: path)
        }
        return appSupportURL.appendingPathComponent("config.toml")
    }

    static var binURL: URL {
        appSupportURL.appendingPathComponent("bin")
    }

    static var diagnosticsURL: URL {
        appSupportURL.appendingPathComponent("diagnostics")
    }

    static var daemonBinaryURL: URL {
        binURL.appendingPathComponent("baxterd")
    }

    static var cliBinaryURL: URL {
        binURL.appendingPathComponent("baxter")
    }

    static var daemonLabel: String {
        trimmedEnvironmentValue("BAXTER_LAUNCHD_LABEL") ?? defaultDaemonLabel
    }

    static var bundledLaunchAgentPlistName: String {
        "\(defaultDaemonLabel).plist"
    }

    static var bundledLaunchAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent(bundledLaunchAgentPlistName)
    }

    static var bundledDaemonLauncherURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("bin")
            .appendingPathComponent("baxterd-launch.sh")
    }

    static var bundledDaemonBinaryURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("bin")
            .appendingPathComponent("baxterd")
    }

    static func shouldUseBundledLaunchAgent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledPlistExists: Bool = FileManager.default.fileExists(atPath: bundledLaunchAgentURL.path),
        bundledLauncherExecutable: Bool = FileManager.default.isExecutableFile(atPath: bundledDaemonLauncherURL.path),
        bundledDaemonExecutable: Bool = FileManager.default.isExecutableFile(atPath: bundledDaemonBinaryURL.path)
    ) -> Bool {
        guard bundledPlistExists, bundledLauncherExecutable, bundledDaemonExecutable else {
            return false
        }
        for name in appServiceBlockingEnvironmentVariables {
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                return false
            }
        }
        return true
    }

    static var launchAgentURL: URL {
        homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(daemonLabel).plist")
    }

    static var ipcAddress: String {
        trimmedEnvironmentValue("BAXTER_IPC_ADDR") ?? defaultIPCAddress
    }

    static var daemonBaseURL: URL {
        URL(string: "http://\(ipcAddress)")!
    }

    static var daemonOutLogURL: URL {
        homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("\(defaultLogStem).out.log")
    }

    static var daemonErrLogURL: URL {
        homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("\(defaultLogStem).err.log")
    }
}
