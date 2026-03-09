import AppKit
import Foundation

enum BackupSchedule: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case manual

    var id: String { rawValue }
}

enum WeekdayOption: String, CaseIterable, Identifiable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }
}

enum StorageModeOption: String, CaseIterable, Identifiable {
    case local
    case s3

    var id: String { rawValue }
}

struct BaxterConfig {
    var backupRoots: [String]
    var excludePaths: [String]
    var excludeGlobs: [String]
    var schedule: BackupSchedule
    var dailyTime: String
    var weeklyDay: WeekdayOption
    var weeklyTime: String
    var s3Endpoint: String
    var s3Region: String
    var s3Bucket: String
    var s3Prefix: String
    var s3AWSProfile: String
    var keychainService: String
    var keychainAccount: String
    var verifySchedule: BackupSchedule
    var verifyDailyTime: String
    var verifyWeeklyDay: WeekdayOption
    var verifyWeeklyTime: String
    var verifyPrefix: String
    var verifyLimit: Int
    var verifySample: Int

    static let `default` = BaxterConfig(
        backupRoots: [],
        excludePaths: [],
        excludeGlobs: [],
        schedule: .daily,
        dailyTime: "09:00",
        weeklyDay: .sunday,
        weeklyTime: "09:00",
        s3Endpoint: "",
        s3Region: "",
        s3Bucket: "",
        s3Prefix: "baxter/",
        s3AWSProfile: "",
        keychainService: "baxter",
        keychainAccount: "default",
        verifySchedule: .manual,
        verifyDailyTime: "09:00",
        verifyWeeklyDay: .sunday,
        verifyWeeklyTime: "09:00",
        verifyPrefix: "",
        verifyLimit: 0,
        verifySample: 0
    )
}

enum SettingsField: Hashable {
    case backupRoots
    case excludePaths
    case excludeGlobs
    case dailyTime
    case weeklyDay
    case weeklyTime
    case s3Endpoint
    case s3Region
    case s3Bucket
    case s3Prefix
    case s3AWSProfile
    case keychainService
    case keychainAccount
    case verifyDailyTime
    case verifyWeeklyDay
    case verifyWeeklyTime
    case verifyLimit
    case verifySample
}

enum SettingsError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        }
    }
}

struct DaemonStatus: Decodable {
    let state: String
    let verifyState: String?
    let lastBackupAt: String?
    let nextScheduledAt: String?
    let lastError: String?
    let lastRestoreAt: String?
    let lastRestorePath: String?
    let lastRestoreError: String?
    let lastVerifyAt: String?
    let nextVerifyAt: String?
    let lastVerifyError: String?
    let lastVerifyChecked: Int?
    let lastVerifyOK: Int?
    let lastVerifyMissing: Int?
    let lastVerifyReadErrors: Int?
    let lastVerifyDecryptErrors: Int?
    let lastVerifyChecksumErrors: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case verifyState = "verify_state"
        case lastBackupAt = "last_backup_at"
        case nextScheduledAt = "next_scheduled_at"
        case lastError = "last_error"
        case lastRestoreAt = "last_restore_at"
        case lastRestorePath = "last_restore_path"
        case lastRestoreError = "last_restore_error"
        case lastVerifyAt = "last_verify_at"
        case nextVerifyAt = "next_verify_at"
        case lastVerifyError = "last_verify_error"
        case lastVerifyChecked = "last_verify_checked"
        case lastVerifyOK = "last_verify_ok"
        case lastVerifyMissing = "last_verify_missing"
        case lastVerifyReadErrors = "last_verify_read_errors"
        case lastVerifyDecryptErrors = "last_verify_decrypt_errors"
        case lastVerifyChecksumErrors = "last_verify_checksum_errors"
    }
}

struct RestoreListPayload: Decodable {
    let paths: [String]
}

struct RestoreBrowserNode: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let children: [RestoreBrowserNode]
    let isPlaceholder: Bool

    var id: String { path }
    var childNodes: [RestoreBrowserNode]? { children.isEmpty ? nil : children }

    init(
        path: String,
        name: String,
        isDirectory: Bool,
        children: [RestoreBrowserNode],
        isPlaceholder: Bool = false
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.isPlaceholder = isPlaceholder
    }
}

struct RestoreBrowserIndex {
    let rootNodes: [RestoreBrowserNode]
    let isDirectoryByPath: [String: Bool]
    let didTruncate: Bool
}

func buildRestoreBrowserIndex(paths: [String], maxPaths: Int) -> RestoreBrowserIndex {
    var explicitDirectoryPaths: Set<String> = []
    var normalizedPaths: Set<String> = []

    for rawPath in paths {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = normalizedRestorePath(trimmed) else {
            continue
        }
        normalizedPaths.insert(normalized)
        if trimmed != "/", trimmed.hasSuffix("/") {
            explicitDirectoryPaths.insert(normalized)
        }
    }

    let sortedPaths = normalizedPaths.sorted()
    let truncated = maxPaths > 0 && sortedPaths.count > maxPaths
    let limitedPaths = maxPaths > 0 ? Array(sortedPaths.prefix(maxPaths)) : sortedPaths

    let root = MutableRestoreBrowserNode(path: "", name: "", isDirectory: true)
    for path in limitedPaths {
        insertRestorePath(path, treatLeafAsDirectory: explicitDirectoryPaths.contains(path), root: root)
    }

    var isDirectoryByPath: [String: Bool] = [:]
    let rootNodes = finalizeRestoreBrowserNodes(
        Array(root.children.values),
        isDirectoryByPath: &isDirectoryByPath
    )
    return RestoreBrowserIndex(
        rootNodes: rootNodes,
        isDirectoryByPath: isDirectoryByPath,
        didTruncate: truncated
    )
}

func filterRestoreBrowserNodes(_ nodes: [RestoreBrowserNode], query: String) -> [RestoreBrowserNode] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
        return nodes
    }
    return nodes.compactMap { filterRestoreBrowserNode($0, query: trimmedQuery) }
}

func flattenRestoreBrowserNodePaths(_ nodes: [RestoreBrowserNode]) -> [String] {
    var paths: [String] = []
    appendRestoreBrowserNodePaths(nodes, into: &paths)
    return paths
}

func countRestoreBrowserNodes(_ nodes: [RestoreBrowserNode]) -> Int {
    nodes.reduce(0) { partialResult, node in
        partialResult + 1 + countRestoreBrowserNodes(node.children)
    }
}

func restorePathName(_ path: String) -> String {
    if path == "/" {
        return "/"
    }
    return path
        .split(separator: "/", omittingEmptySubsequences: true)
        .last
        .map(String.init) ?? path
}

func restoreParentPath(_ path: String) -> String {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty, trimmedPath != "/" else {
        return "/"
    }

    let isAbsolute = trimmedPath.hasPrefix("/")
    let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1 else {
        return "/"
    }

    let parent = components.dropLast().joined(separator: "/")
    return isAbsolute ? "/\(parent)" : parent
}

struct SnapshotSummary: Decodable, Identifiable, Hashable {
    let id: String
    let createdAt: String
    let entries: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case entries
    }
}

struct SnapshotsPayload: Decodable {
    let snapshots: [SnapshotSummary]
}

struct RestoreActionRequest: Encodable {
    let path: String
    let toDir: String?
    let overwrite: Bool
    let verifyOnly: Bool?
    let snapshot: String?

    enum CodingKeys: String, CodingKey {
        case path
        case toDir = "to_dir"
        case overwrite
        case verifyOnly = "verify_only"
        case snapshot
    }

    init(path: String, toDir: String, overwrite: Bool, verifyOnly: Bool? = nil, snapshot: String) {
        self.path = path
        self.toDir = toDir.isEmpty ? nil : toDir
        self.overwrite = overwrite
        self.verifyOnly = verifyOnly
        self.snapshot = snapshot.isEmpty ? nil : snapshot
    }
}

struct RestoreDryRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let overwrite: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case overwrite
    }
}

struct RestoreRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let verified: Bool
    let wrote: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case verified
        case wrote
    }
}

struct DaemonErrorPayload: Decodable {
    let code: String
    let message: String
}

enum IPCError: Error {
    case badResponse
    case badStatus(Int)
    case server(code: String, message: String, statusCode: Int)
    case reloadUnavailable
}

extension IPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Unexpected daemon response."
        case .badStatus(let statusCode):
            return "Daemon returned HTTP \(statusCode)."
        case .server(_, let message, _):
            return message
        case .reloadUnavailable:
            return "Reload endpoint unavailable."
        }
    }
}

private final class MutableRestoreBrowserNode {
    let path: String
    let name: String
    var isDirectory: Bool
    var children: [String: MutableRestoreBrowserNode] = [:]

    init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

private func normalizedRestorePath(_ rawPath: String) -> String? {
    guard !rawPath.isEmpty else {
        return nil
    }

    if rawPath == "/" {
        return rawPath
    }

    var normalized = rawPath
    while normalized.count > 1, normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized.isEmpty ? nil : normalized
}

private func insertRestorePath(
    _ path: String,
    treatLeafAsDirectory: Bool,
    root: MutableRestoreBrowserNode
) {
    guard path != "/" else {
        return
    }

    let isAbsolute = path.hasPrefix("/")
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty else {
        return
    }

    var parent = root
    var currentPath = ""
    for (index, component) in components.enumerated() {
        let isLeaf = index == components.count - 1
        let shouldBeDirectory = !isLeaf || treatLeafAsDirectory
        if isAbsolute {
            currentPath += "/\(component)"
        } else if currentPath.isEmpty {
            currentPath = component
        } else {
            currentPath += "/\(component)"
        }

        let child = parent.children[currentPath] ?? MutableRestoreBrowserNode(
            path: currentPath,
            name: component,
            isDirectory: shouldBeDirectory
        )
        child.isDirectory = child.isDirectory || shouldBeDirectory
        parent.children[currentPath] = child
        parent = child
    }
}

private func finalizeRestoreBrowserNodes(
    _ nodes: [MutableRestoreBrowserNode],
    isDirectoryByPath: inout [String: Bool]
) -> [RestoreBrowserNode] {
    let sortedNodes = nodes.sorted(by: compareRestoreBrowserNodes)
    return sortedNodes.map { mutableNode in
        let children = finalizeRestoreBrowserNodes(
            Array(mutableNode.children.values),
            isDirectoryByPath: &isDirectoryByPath
        )
        isDirectoryByPath[mutableNode.path] = mutableNode.isDirectory || !children.isEmpty
        return RestoreBrowserNode(
            path: mutableNode.path,
            name: mutableNode.name,
            isDirectory: mutableNode.isDirectory || !children.isEmpty,
            children: children
        )
    }
}

private func compareRestoreBrowserNodes(_ lhs: MutableRestoreBrowserNode, _ rhs: MutableRestoreBrowserNode) -> Bool {
    if lhs.isDirectory != rhs.isDirectory {
        return lhs.isDirectory && !rhs.isDirectory
    }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}

private func filterRestoreBrowserNode(_ node: RestoreBrowserNode, query: String) -> RestoreBrowserNode? {
    let matchingChildren = node.children.compactMap { filterRestoreBrowserNode($0, query: query) }
    let matchesNode = node.name.localizedCaseInsensitiveContains(query) || node.path.localizedCaseInsensitiveContains(query)
    if matchesNode {
        return node
    }
    guard !matchingChildren.isEmpty else {
        return nil
    }
    return RestoreBrowserNode(
        path: node.path,
        name: node.name,
        isDirectory: node.isDirectory,
        children: matchingChildren
    )
}

private func appendRestoreBrowserNodePaths(_ nodes: [RestoreBrowserNode], into paths: inout [String]) {
    for node in nodes {
        paths.append(node.path)
        appendRestoreBrowserNodePaths(node.children, into: &paths)
    }
}
