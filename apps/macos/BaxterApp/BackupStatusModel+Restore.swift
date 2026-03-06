import Foundation

extension BackupStatusModel {
    func fetchRestoreList(prefix: String, contains: String, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }
            do {
                let paths = try await fetchRestorePaths(
                    prefix: prefix,
                    contains: contains,
                    snapshot: snapshot,
                    childrenOnly: false
                )
                restorePaths = paths
                restorePreviewMessage = "Found \(paths.count) path(s)."
            } catch {
                restorePreviewMessage = "Restore list failed: \(error.localizedDescription)"
            }
        }
    }

    func fetchRestorePaths(
        prefix: String,
        contains: String,
        snapshot: String,
        childrenOnly: Bool
    ) async throws -> [String] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/restore/list"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrefix.isEmpty {
            queryItems.append(URLQueryItem(name: "prefix", value: trimmedPrefix))
        }
        let trimmedContains = contains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContains.isEmpty {
            queryItems.append(URLQueryItem(name: "contains", value: trimmedContains))
        }
        let trimmedSnapshot = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSnapshot.isEmpty {
            queryItems.append(URLQueryItem(name: "snapshot", value: trimmedSnapshot))
        }
        if childrenOnly {
            queryItems.append(URLQueryItem(name: "children", value: "1"))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw IPCError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyIPCAuthHeader(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IPCError.badResponse
        }
        guard http.statusCode == 200 else {
            throw decodeDaemonError(data: data, statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(RestoreListPayload.self, from: data)
        return decoded.paths
    }

    func fetchSnapshots(limit: Int = 50) {
        Task {
            isSnapshotsBusy = true
            defer { isSnapshotsBusy = false }

            do {
                var components = URLComponents(url: baseURL.appendingPathComponent("v1/snapshots"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "limit", value: String(max(limit, 0)))]
                guard let url = components?.url else {
                    throw IPCError.badResponse
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }

                let decoded = try JSONDecoder().decode(SnapshotsPayload.self, from: data)
                snapshots = decoded.snapshots
                if selectedSnapshot != Self.latestSnapshotSelection &&
                    !decoded.snapshots.contains(where: { $0.id == selectedSnapshot }) {
                    selectedSnapshot = Self.latestSnapshotSelection
                }
                snapshotsMessage = decoded.snapshots.isEmpty
                    ? "No snapshots found. Use latest."
                    : "Loaded \(decoded.snapshots.count) snapshot(s)."
            } catch {
                snapshotsMessage = "Snapshot load failed: \(error.localizedDescription)"
            }
        }
    }

    var selectedSnapshotRequestValue: String {
        selectedSnapshot == Self.latestSnapshotSelection ? "" : selectedSnapshot
    }

    var selectedSnapshotSummary: SnapshotSummary? {
        snapshots.first(where: { $0.id == selectedSnapshot })
    }

    func previewRestore(path: String, toDir: String, overwrite: Bool, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty {
                restorePreviewMessage = "Enter a restore path."
                return
            }

            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/restore/dry-run"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyIPCAuthHeader(to: &request)
                let payload = RestoreActionRequest(
                    path: trimmedPath,
                    toDir: toDir.trimmingCharacters(in: .whitespacesAndNewlines),
                    overwrite: overwrite,
                    snapshot: snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                request.httpBody = try JSONEncoder().encode(payload)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(RestoreDryRunPayload.self, from: data)
                restorePreviewMessage = "Dry-run: source=\(decoded.sourcePath) target=\(decoded.targetPath) overwrite=\(decoded.overwrite)"
            } catch {
                restorePreviewMessage = formatRestoreError(prefix: "Restore dry-run", error: error)
            }
        }
    }

    func runRestore(path: String, toDir: String, overwrite: Bool, verifyOnly: Bool, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty {
                restorePreviewMessage = "Enter a restore path."
                return
            }

            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/restore/run"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyIPCAuthHeader(to: &request)
                let payload = RestoreActionRequest(
                    path: trimmedPath,
                    toDir: toDir.trimmingCharacters(in: .whitespacesAndNewlines),
                    overwrite: overwrite,
                    verifyOnly: verifyOnly,
                    snapshot: snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                request.httpBody = try JSONEncoder().encode(payload)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(RestoreRunPayload.self, from: data)
                if decoded.wrote {
                    restorePreviewMessage = "Restore complete: source=\(decoded.sourcePath) target=\(decoded.targetPath)"
                } else if decoded.verified {
                    restorePreviewMessage = "Restore verify-only complete: source=\(decoded.sourcePath) target=\(decoded.targetPath)"
                } else {
                    restorePreviewMessage = "Restore response received for source=\(decoded.sourcePath)"
                }
                refreshStatus()
            } catch {
                restorePreviewMessage = formatRestoreError(prefix: "Restore", error: error)
            }
        }
    }

    private func formatRestoreError(prefix: String, error: Error) -> String {
        if case IPCError.server(let code, let message, _) = error {
            let guidance = restoreErrorGuidance(for: code)
            if let guidance {
                return "\(prefix) failed [\(code)]: \(guidance)"
            }
            return "\(prefix) failed [\(code)]: \(message)"
        }
        return "\(prefix) failed: \(error.localizedDescription)"
    }

    private func restoreErrorGuidance(for code: String) -> String? {
        switch code {
        case "manifest_load_failed":
            return "Could not load the selected snapshot. Refresh snapshots and try again."
        case "path_lookup_failed":
            return "The requested path was not found in the selected snapshot."
        case "invalid_restore_target":
            return "The destination path is invalid or escapes the selected destination root."
        case "target_exists":
            return "The destination file already exists. Enable overwrite or choose a different destination."
        case "restore_object_missing":
            return "Backup data for this path is missing. Try another snapshot or run a new backup."
        case "restore_storage_transient":
            return "Temporary storage error while reading backup data. Retry in a moment."
        case "restore_key_unavailable":
            return "Restore key is unavailable. Check BAXTER_PASSPHRASE or keychain settings."
        case "decrypt_failed":
            return "Could not decrypt backup data. Verify the configured encryption key."
        case "integrity_check_failed":
            return "Integrity verification failed for restored content. Retry from another snapshot."
        default:
            return nil
        }
    }
}
