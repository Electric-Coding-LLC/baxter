import Foundation

extension BackupStatusModel {
    func runBackup() {
        Task {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/backup/run"))
                request.httpMethod = "POST"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 202 {
                    refreshStatus()
                    return
                }
                if http.statusCode == 409 {
                    state = .running
                    lastError = nil
                    return
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch {
                state = .failed
                lastError = "run failed: \(error.localizedDescription)"
            }
        }
    }

    func runVerify() {
        Task {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/verify/run"))
                request.httpMethod = "POST"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 202 {
                    refreshStatus()
                    return
                }
                if http.statusCode == 409 {
                    verifyState = .running
                    lastVerifyError = nil
                    return
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch {
                verifyState = .failed
                lastVerifyError = "verify failed: \(error.localizedDescription)"
            }
        }
    }

    func startDaemon() {
        Task {
            activeLifecycleAction = .starting
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                lifecycleMessage = try await startLaunchd()
                suppressAutoRecoveryUntilManualStart = false
                lastError = nil
                connectionState = .connecting
                ipcUnavailableSince = nowProvider()
                refreshStatus()
            } catch {
                lifecycleMessage = "Start failed: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        Task {
            activeLifecycleAction = .stopping
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                lifecycleMessage = try await stopLaunchd()
                suppressAutoRecoveryUntilManualStart = true
                lastError = nil
                connectionState = .stopped
                ipcUnavailableSince = nil
                refreshStatus()
            } catch {
                lifecycleMessage = "Stop failed: \(error.localizedDescription)"
            }
        }
    }

    func applyConfigNow() {
        Task {
            activeLifecycleAction = .applyingConfig
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/config/reload"))
                request.httpMethod = "POST"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 200 {
                    lifecycleMessage = "Config reloaded."
                    lastError = nil
                    refreshStatus()
                    return
                }
                if http.statusCode == 404 || http.statusCode == 405 {
                    throw IPCError.reloadUnavailable
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch IPCError.reloadUnavailable {
                do {
                    lifecycleMessage = "Reload unavailable; restarting daemon..."
                    lifecycleMessage = try await startLaunchd()
                    lastError = nil
                    connectionState = .connecting
                    ipcUnavailableSince = nowProvider()
                    refreshStatus()
                } catch {
                    lifecycleMessage = "Apply failed: \(error.localizedDescription)"
                }
            } catch {
                lifecycleMessage = "Apply failed: \(error.localizedDescription)"
            }
        }
    }

    func secondsUntilNextAutoRefresh(now: Date = Date()) -> Int? {
        guard let nextAutomaticRefreshAt else {
            return nil
        }
        let remaining = nextAutomaticRefreshAt.timeIntervalSince(now)
        return max(0, Int(ceil(remaining)))
    }
}
