package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"baxter/internal/backup"
	"baxter/internal/crypto"
	"baxter/internal/state"
)

const maxJSONRequestBodyBytes = 1 << 20

func (d *Daemon) newHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/status", d.handleStatus)
	mux.HandleFunc("/v1/backup/run", d.requireIPCWriteAuth(d.handleRunBackup))
	mux.HandleFunc("/v1/verify/run", d.requireIPCWriteAuth(d.handleRunVerify))
	mux.HandleFunc("/v1/config/reload", d.requireIPCWriteAuth(d.handleReloadConfig))
	mux.HandleFunc("/v1/snapshots", d.handleSnapshots)
	mux.HandleFunc("/v1/restore/list", d.handleRestoreList)
	mux.HandleFunc("/v1/restore/dry-run", d.handleRestoreDryRun)
	mux.HandleFunc("/v1/restore/run", d.requireIPCWriteAuth(d.handleRestoreRun))
	return mux
}

func (d *Daemon) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	d.writeJSON(w, http.StatusOK, d.snapshot())
}

func (d *Daemon) handleRunBackup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	if err := d.triggerBackup(); err != nil {
		if errors.Is(err, errBackupAlreadyRunning) {
			d.writeError(w, http.StatusConflict, "backup_running", err.Error())
			return
		}
		d.writeError(w, http.StatusBadRequest, "backup_start_failed", err.Error())
		return
	}

	d.writeJSON(w, http.StatusAccepted, map[string]string{"status": "started"})
}

func (d *Daemon) handleRunVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	if err := d.triggerVerify(); err != nil {
		if errors.Is(err, errVerifyAlreadyRunning) {
			d.writeError(w, http.StatusConflict, "verify_running", err.Error())
			return
		}
		d.writeError(w, http.StatusBadRequest, "verify_start_failed", err.Error())
		return
	}

	d.writeJSON(w, http.StatusAccepted, map[string]string{"status": "started"})
}

func (d *Daemon) handleReloadConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	_, err := d.reloadConfig()
	if err != nil {
		d.setLastError(fmt.Sprintf("config reload failed: %v", err))
		d.writeError(w, http.StatusBadRequest, "config_reload_failed", err.Error())
		return
	}

	d.setLastError("")
	d.notifyScheduleChanged()
	d.writeJSON(w, http.StatusOK, map[string]string{"status": "reloaded"})
}

func (d *Daemon) handleRestoreList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	snapshotSelector := strings.TrimSpace(r.URL.Query().Get("snapshot"))
	m, err := d.loadManifestForRestore(snapshotSelector)
	if err != nil {
		d.writeError(w, http.StatusBadRequest, "manifest_load_failed", fmt.Sprintf("load manifest: %v", err))
		return
	}

	prefix := strings.TrimSpace(r.URL.Query().Get("prefix"))
	contains := strings.TrimSpace(r.URL.Query().Get("contains"))
	paths := filterRestorePaths(m.Entries, prefix, contains)
	d.writeJSON(w, http.StatusOK, restoreListResponse{Paths: paths})
}

func (d *Daemon) handleSnapshots(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	limit := 20
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed < 0 {
			d.writeError(w, http.StatusBadRequest, "invalid_request", "limit must be >= 0")
			return
		}
		limit = parsed
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		d.writeError(w, http.StatusInternalServerError, "state_path_failed", err.Error())
		return
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		d.writeError(w, http.StatusBadRequest, "snapshot_list_failed", fmt.Sprintf("list snapshots: %v", err))
		return
	}

	if limit > 0 && limit < len(snapshots) {
		snapshots = snapshots[:limit]
	}

	resp := snapshotsResponse{
		Snapshots: make([]snapshotSummary, 0, len(snapshots)),
	}
	for _, snapshot := range snapshots {
		resp.Snapshots = append(resp.Snapshots, snapshotSummary{
			ID:        snapshot.ID,
			CreatedAt: snapshot.CreatedAt.Format(time.RFC3339),
			Entries:   snapshot.Entries,
		})
	}
	d.writeJSON(w, http.StatusOK, resp)
}

func (d *Daemon) handleRestoreDryRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	var req restoreDryRunRequest
	if err := decodeJSONRequest(w, r, &req); err != nil {
		d.writeError(w, http.StatusBadRequest, "invalid_request", fmt.Sprintf("decode request: %v", err))
		return
	}
	requestedPath := strings.TrimSpace(req.Path)
	if requestedPath == "" {
		d.writeError(w, http.StatusBadRequest, "invalid_request", "path is required")
		return
	}

	entry, targetPath, err := d.resolveRestoreTarget(requestedPath, req.ToDir, req.Snapshot)
	if err != nil {
		d.writeRestoreError(w, err)
		return
	}

	d.writeJSON(w, http.StatusOK, restoreDryRunResponse{
		SourcePath: entry.Path,
		TargetPath: targetPath,
		Overwrite:  req.Overwrite,
	})
}

func (d *Daemon) handleRestoreRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	var req restoreRunRequest
	if err := decodeJSONRequest(w, r, &req); err != nil {
		d.writeError(w, http.StatusBadRequest, "invalid_request", fmt.Sprintf("decode request: %v", err))
		return
	}
	requestedPath := strings.TrimSpace(req.Path)
	if requestedPath == "" {
		d.writeError(w, http.StatusBadRequest, "invalid_request", "path is required")
		return
	}

	entry, targetPath, err := d.resolveRestoreTarget(requestedPath, req.ToDir, req.Snapshot)
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeRestoreError(w, err)
		return
	}

	cfg := d.currentConfig()
	store, err := d.objectStore(cfg)
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusInternalServerError, "object_store_failed", err.Error())
		return
	}

	keys, err := encryptionKeys(cfg)
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "restore_key_unavailable", err.Error())
		return
	}

	payload, err := store.GetObject(backup.ObjectKeyForPath(entry.Path))
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "read_object_failed", fmt.Sprintf("read object: %v", err))
		return
	}

	plain, err := crypto.DecryptBytesWithAnyKey(keys.candidates, payload)
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "decrypt_failed", fmt.Sprintf("decrypt object: %v", err))
		return
	}
	if err := backup.VerifyEntryContent(entry, plain); err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "integrity_check_failed", err.Error())
		return
	}

	if req.VerifyOnly {
		d.setRestoreSuccess(entry.Path)
		d.writeJSON(w, http.StatusOK, restoreRunResponse{
			SourcePath: entry.Path,
			TargetPath: targetPath,
			Verified:   true,
			Wrote:      false,
		})
		return
	}

	if !req.Overwrite {
		if _, err := os.Stat(targetPath); err == nil {
			msg := fmt.Sprintf("target exists: %s (use overwrite=true to replace)", targetPath)
			d.setLastRestoreError(msg)
			d.writeError(w, http.StatusBadRequest, "target_exists", msg)
			return
		} else if !os.IsNotExist(err) {
			d.setLastRestoreError(err.Error())
			d.writeError(w, http.StatusBadRequest, "write_failed", err.Error())
			return
		}
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "write_failed", err.Error())
		return
	}
	if err := os.WriteFile(targetPath, plain, entry.Mode.Perm()); err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "write_failed", err.Error())
		return
	}

	d.setRestoreSuccess(entry.Path)
	d.writeJSON(w, http.StatusOK, restoreRunResponse{
		SourcePath: entry.Path,
		TargetPath: targetPath,
		Verified:   true,
		Wrote:      true,
	})
}

func decodeJSONRequest(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONRequestBodyBytes)
	return json.NewDecoder(r.Body).Decode(dst)
}

func (d *Daemon) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (d *Daemon) writeError(w http.ResponseWriter, status int, code string, message string) {
	d.writeJSON(w, status, errorResponse{
		Code:    code,
		Message: message,
	})
}
