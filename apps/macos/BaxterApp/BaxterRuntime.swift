import Foundation

enum BaxterRuntime {
    #if DEBUG
    private static let defaultStateDirectoryName = "baxter-dev"
    private static let defaultDaemonLabel = "com.electriccoding.baxterd.dev"
    private static let defaultIPCAddress = "127.0.0.1:43129"
    private static let defaultLogStem = "baxterd-dev"
    #else
    private static let defaultStateDirectoryName = "baxter"
    private static let defaultDaemonLabel = "com.electriccoding.baxterd"
    private static let defaultIPCAddress = "127.0.0.1:41820"
    private static let defaultLogStem = "baxterd"
    #endif

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
