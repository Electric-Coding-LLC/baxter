package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

const DefaultIPCAddress = "127.0.0.1:41820"
const passphraseEnv = "BAXTER_PASSPHRASE"

type daemonStatus struct {
	State            string
	LastBackupAt     time.Time
	NextScheduledAt  time.Time
	LastError        string
	LastRestoreAt    time.Time
	LastRestorePath  string
	LastRestoreError string
}

type statusResponse struct {
	State            string `json:"state"`
	LastBackupAt     string `json:"last_backup_at,omitempty"`
	NextScheduledAt  string `json:"next_scheduled_at,omitempty"`
	LastError        string `json:"last_error,omitempty"`
	LastRestoreAt    string `json:"last_restore_at,omitempty"`
	LastRestorePath  string `json:"last_restore_path,omitempty"`
	LastRestoreError string `json:"last_restore_error,omitempty"`
}

type restoreListResponse struct {
	Paths []string `json:"paths"`
}

type restoreDryRunRequest struct {
	Path      string `json:"path"`
	ToDir     string `json:"to_dir,omitempty"`
	Overwrite bool   `json:"overwrite,omitempty"`
}

type restoreDryRunResponse struct {
	SourcePath string `json:"source_path"`
	TargetPath string `json:"target_path"`
	Overwrite  bool   `json:"overwrite"`
}

type restoreRunRequest struct {
	Path      string `json:"path"`
	ToDir     string `json:"to_dir,omitempty"`
	Overwrite bool   `json:"overwrite,omitempty"`
}

type restoreRunResponse struct {
	SourcePath string `json:"source_path"`
	TargetPath string `json:"target_path"`
}

type errorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type scheduleConfig struct {
	Schedule   string
	DailyTime  string
	WeeklyDay  string
	WeeklyTime string
}

type Daemon struct {
	cfg             *config.Config
	configPath      string
	configLoader    func(string) (*config.Config, error)
	clockNow        func() time.Time
	timerAfter      func(time.Duration) <-chan time.Time
	backupRunner    func(context.Context, *config.Config) error
	scheduleChanged chan struct{}
	ipcAddr         string
	mu              sync.Mutex
	running         bool
	status          daemonStatus
	handler         http.Handler
}

func New(cfg *config.Config) *Daemon {
	d := &Daemon{
		cfg:             cfg,
		configLoader:    config.Load,
		clockNow:        time.Now,
		timerAfter:      time.After,
		scheduleChanged: make(chan struct{}, 1),
		ipcAddr:         DefaultIPCAddress,
		status: daemonStatus{
			State: "idle",
		},
	}
	d.backupRunner = d.performBackup
	d.handler = d.newHandler()
	return d
}

func (d *Daemon) SetIPCAddress(addr string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if addr != "" {
		d.ipcAddr = addr
	}
}

func (d *Daemon) SetConfigPath(path string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.configPath = path
}

func (d *Daemon) Handler() http.Handler {
	return d.handler
}

func (d *Daemon) Run(ctx context.Context) error {
	fmt.Printf("baxterd listening on %s\n", d.ipcAddr)

	srv := &http.Server{
		Addr:    d.ipcAddr,
		Handler: d.Handler(),
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	go d.runScheduler(ctx)

	err := srv.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func (d *Daemon) runScheduler(ctx context.Context) {
	for {
		now := d.now()
		schedule := d.scheduleConfig()
		nextRun, enabled := nextScheduledRun(schedule, now)
		if !enabled {
			fmt.Printf("scheduler disabled: schedule=%s\n", schedule.Schedule)
			d.setNextScheduledAt(time.Time{})
			select {
			case <-ctx.Done():
				return
			case <-d.scheduleChanged:
				continue
			}
		}

		d.setNextScheduledAt(nextRun)
		wait := time.Until(nextRun)
		if wait < 0 {
			wait = 0
		}
		fmt.Printf("scheduler next run: schedule=%s next=%s wait=%s\n", schedule.Schedule, nextRun.Format(time.RFC3339), wait)

		select {
		case <-ctx.Done():
			return
		case <-d.scheduleChanged:
			fmt.Printf("scheduler config changed: recomputing next run\n")
			continue
		case <-d.timerAfter(wait):
			if err := d.triggerBackup(); err != nil && !errors.Is(err, errBackupAlreadyRunning) {
				d.setFailed(err)
			}
		}
	}
}

func (d *Daemon) now() time.Time {
	return d.clockNow()
}

func (d *Daemon) scheduleConfig() scheduleConfig {
	d.mu.Lock()
	defer d.mu.Unlock()
	return scheduleConfig{
		Schedule:   d.cfg.Schedule,
		DailyTime:  d.cfg.DailyTime,
		WeeklyDay:  d.cfg.WeeklyDay,
		WeeklyTime: d.cfg.WeeklyTime,
	}
}

func nextScheduledRun(cfg scheduleConfig, now time.Time) (time.Time, bool) {
	switch cfg.Schedule {
	case "daily":
		hour, minute, ok := parseHHMM(cfg.DailyTime)
		if !ok {
			return time.Time{}, false
		}
		return nextDailyRun(now, hour, minute), true
	case "weekly":
		weekday, ok := parseWeekday(cfg.WeeklyDay)
		if !ok {
			return time.Time{}, false
		}
		hour, minute, ok := parseHHMM(cfg.WeeklyTime)
		if !ok {
			return time.Time{}, false
		}
		return nextWeeklyRun(now, weekday, hour, minute), true
	default:
		return time.Time{}, false
	}
}

func nextDailyRun(now time.Time, hour int, minute int) time.Time {
	return nextRunAtLocalTime(now, hour, minute, nil)
}

func nextWeeklyRun(now time.Time, weekday time.Weekday, hour int, minute int) time.Time {
	return nextRunAtLocalTime(now, hour, minute, &weekday)
}

func nextRunAtLocalTime(now time.Time, hour int, minute int, weeklyDay *time.Weekday) time.Time {
	loc := now.Location()
	if loc == nil {
		loc = time.Local
	}

	nowLocal := now.In(loc)
	candidate := time.Date(
		nowLocal.Year(),
		nowLocal.Month(),
		nowLocal.Day(),
		hour,
		minute,
		0,
		0,
		loc,
	)

	if weeklyDay != nil {
		daysAhead := (int(*weeklyDay) - int(nowLocal.Weekday()) + 7) % 7
		candidate = candidate.AddDate(0, 0, daysAhead)
		if !candidate.After(nowLocal) {
			candidate = candidate.AddDate(0, 0, 7)
		}
		return candidate
	}

	if !candidate.After(nowLocal) {
		candidate = candidate.AddDate(0, 0, 1)
	}
	return candidate
}

func parseHHMM(value string) (int, int, bool) {
	if len(value) != 5 || value[2] != ':' {
		return 0, 0, false
	}
	hourTens := value[0]
	hourOnes := value[1]
	minuteTens := value[3]
	minuteOnes := value[4]
	if hourTens < '0' || hourTens > '2' || hourOnes < '0' || hourOnes > '9' {
		return 0, 0, false
	}
	if minuteTens < '0' || minuteTens > '5' || minuteOnes < '0' || minuteOnes > '9' {
		return 0, 0, false
	}
	hour := int(hourTens-'0')*10 + int(hourOnes-'0')
	minute := int(minuteTens-'0')*10 + int(minuteOnes-'0')
	if hour < 0 || hour > 23 {
		return 0, 0, false
	}
	return hour, minute, true
}

func parseWeekday(value string) (time.Weekday, bool) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "sunday":
		return time.Sunday, true
	case "monday":
		return time.Monday, true
	case "tuesday":
		return time.Tuesday, true
	case "wednesday":
		return time.Wednesday, true
	case "thursday":
		return time.Thursday, true
	case "friday":
		return time.Friday, true
	case "saturday":
		return time.Saturday, true
	default:
		return time.Sunday, false
	}
}

func (d *Daemon) RunOnce(ctx context.Context) error {
	if err := d.backupRunner(ctx, d.currentConfig()); err != nil {
		d.setFailed(err)
		return err
	}
	d.setIdleSuccess()
	return nil
}

func (d *Daemon) newHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/status", d.handleStatus)
	mux.HandleFunc("/v1/backup/run", d.handleRunBackup)
	mux.HandleFunc("/v1/config/reload", d.handleReloadConfig)
	mux.HandleFunc("/v1/restore/list", d.handleRestoreList)
	mux.HandleFunc("/v1/restore/dry-run", d.handleRestoreDryRun)
	mux.HandleFunc("/v1/restore/run", d.handleRestoreRun)
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

	manifestPath, err := state.ManifestPath()
	if err != nil {
		d.writeError(w, http.StatusInternalServerError, "state_path_failed", err.Error())
		return
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		d.writeError(w, http.StatusBadRequest, "manifest_load_failed", fmt.Sprintf("load manifest: %v", err))
		return
	}

	prefix := strings.TrimSpace(r.URL.Query().Get("prefix"))
	contains := strings.TrimSpace(r.URL.Query().Get("contains"))
	paths := filterRestorePaths(m.Entries, prefix, contains)
	d.writeJSON(w, http.StatusOK, restoreListResponse{Paths: paths})
}

func (d *Daemon) handleRestoreDryRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		d.writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	var req restoreDryRunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		d.writeError(w, http.StatusBadRequest, "invalid_request", fmt.Sprintf("decode request: %v", err))
		return
	}
	requestedPath := strings.TrimSpace(req.Path)
	if requestedPath == "" {
		d.writeError(w, http.StatusBadRequest, "invalid_request", "path is required")
		return
	}

	entry, targetPath, err := d.resolveRestoreTarget(requestedPath, req.ToDir)
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		d.writeError(w, http.StatusBadRequest, "invalid_request", fmt.Sprintf("decode request: %v", err))
		return
	}
	requestedPath := strings.TrimSpace(req.Path)
	if requestedPath == "" {
		d.writeError(w, http.StatusBadRequest, "invalid_request", "path is required")
		return
	}

	entry, targetPath, err := d.resolveRestoreTarget(requestedPath, req.ToDir)
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

	key, err := encryptionKey(cfg)
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

	plain, err := crypto.DecryptBytes(key, payload)
	if err != nil {
		d.setLastRestoreError(err.Error())
		d.writeError(w, http.StatusBadRequest, "decrypt_failed", fmt.Sprintf("decrypt object: %v", err))
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
	})
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

var (
	errRestoreStatePath     = errors.New("state path failed")
	errRestoreManifestLoad  = errors.New("manifest load failed")
	errRestorePathLookup    = errors.New("path lookup failed")
	errRestoreTargetInvalid = errors.New("invalid restore target")
)

func (d *Daemon) resolveRestoreTarget(requestedPath string, toDir string) (backup.ManifestEntry, string, error) {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestoreStatePath, err)
	}
	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return backup.ManifestEntry{}, "", fmt.Errorf("%w: load manifest: %v", errRestoreManifestLoad, err)
	}

	entry, err := backup.FindEntryByPath(m, requestedPath)
	if err != nil {
		absPath, absErr := filepath.Abs(requestedPath)
		if absErr != nil {
			return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestorePathLookup, err)
		}
		entry, err = backup.FindEntryByPath(m, absPath)
		if err != nil {
			return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestorePathLookup, err)
		}
	}

	targetPath, err := resolvedRestorePath(entry.Path, toDir)
	if err != nil {
		return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestoreTargetInvalid, err)
	}
	return entry, targetPath, nil
}

func (d *Daemon) writeRestoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errRestoreStatePath):
		d.writeError(w, http.StatusInternalServerError, "state_path_failed", err.Error())
	case errors.Is(err, errRestoreManifestLoad):
		d.writeError(w, http.StatusBadRequest, "manifest_load_failed", err.Error())
	case errors.Is(err, errRestorePathLookup):
		d.writeError(w, http.StatusBadRequest, "path_lookup_failed", err.Error())
	case errors.Is(err, errRestoreTargetInvalid):
		d.writeError(w, http.StatusBadRequest, "invalid_restore_target", err.Error())
	default:
		d.writeError(w, http.StatusBadRequest, "restore_failed", err.Error())
	}
}

func (d *Daemon) objectStore(cfg *config.Config) (storage.ObjectStore, error) {
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return nil, err
	}
	return storage.NewFromConfig(cfg.S3, objectsDir)
}

var errBackupAlreadyRunning = errors.New("backup already running")

func (d *Daemon) triggerBackup() error {
	cfg := d.currentConfig()

	d.mu.Lock()
	if d.running {
		d.mu.Unlock()
		return errBackupAlreadyRunning
	}
	d.running = true
	d.status.State = "running"
	d.status.LastError = ""
	d.mu.Unlock()

	go func() {
		err := d.backupRunner(context.Background(), cfg)
		if err != nil {
			d.setFailed(err)
			return
		}
		d.setIdleSuccess()
	}()
	return nil
}

func (d *Daemon) performBackup(ctx context.Context, cfg *config.Config) error {
	_ = ctx
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	store, err := d.objectStore(cfg)
	if err != nil {
		return fmt.Errorf("create object store: %w", err)
	}
	key, err := encryptionKey(cfg)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:  manifestPath,
		EncryptionKey: key,
		Store:         store,
	})
	if err != nil {
		return err
	}
	fmt.Printf("backup complete: uploaded=%d removed=%d total=%d\n", result.Uploaded, result.Removed, result.Total)
	return nil
}

func encryptionKey(cfg *config.Config) ([]byte, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase != "" {
		return crypto.KeyFromPassphrase(passphrase), nil
	}

	passphrase, err := crypto.PassphraseFromKeychain(cfg.Encryption.KeychainService, cfg.Encryption.KeychainAccount)
	if err != nil {
		return nil, fmt.Errorf("no %s set and keychain lookup failed: %w", passphraseEnv, err)
	}
	return crypto.KeyFromPassphrase(passphrase), nil
}

func (d *Daemon) setFailed(err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.running = false
	d.status.State = "failed"
	d.status.LastError = err.Error()
}

func (d *Daemon) setIdleSuccess() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.running = false
	d.status.State = "idle"
	d.status.LastBackupAt = d.now().UTC()
	d.status.LastError = ""
}

func (d *Daemon) setNextScheduledAt(next time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.NextScheduledAt = next.UTC()
}

func (d *Daemon) setLastError(lastError string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastError = lastError
}

func (d *Daemon) setLastRestoreError(lastRestoreError string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastRestoreError = lastRestoreError
}

func (d *Daemon) setRestoreSuccess(restoredPath string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastRestoreAt = d.now().UTC()
	d.status.LastRestorePath = restoredPath
	d.status.LastRestoreError = ""
}

func (d *Daemon) notifyScheduleChanged() {
	select {
	case d.scheduleChanged <- struct{}{}:
	default:
	}
}

func (d *Daemon) currentConfig() *config.Config {
	d.mu.Lock()
	defer d.mu.Unlock()
	cloned := *d.cfg
	cloned.BackupRoots = append([]string(nil), d.cfg.BackupRoots...)
	return &cloned
}

func filterRestorePaths(entries []backup.ManifestEntry, prefix string, contains string) []string {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	contains = strings.TrimSpace(contains)

	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		path := entry.Path
		if cleanPrefix != "" && !strings.HasPrefix(filepath.Clean(path), cleanPrefix) {
			continue
		}
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}
		paths = append(paths, path)
	}
	return paths
}

func resolvedRestorePath(sourcePath string, toDir string) (string, error) {
	if strings.TrimSpace(toDir) == "" {
		return sourcePath, nil
	}

	cleanToDir := filepath.Clean(toDir)
	cleanSource := filepath.Clean(sourcePath)
	if cleanSource == "." || cleanSource == "" {
		return "", errors.New("invalid restore source path")
	}

	relSource := cleanSource
	if filepath.IsAbs(cleanSource) {
		relSource = strings.TrimPrefix(cleanSource, string(filepath.Separator))
	}
	if relSource == "" || relSource == "." {
		return "", errors.New("invalid restore source path")
	}
	if relSource == ".." || strings.HasPrefix(relSource, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	targetPath := filepath.Join(cleanToDir, relSource)
	targetPath = filepath.Clean(targetPath)

	relToRoot, err := filepath.Rel(cleanToDir, targetPath)
	if err != nil {
		return "", err
	}
	if relToRoot == ".." || strings.HasPrefix(relToRoot, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	return targetPath, nil
}

func (d *Daemon) reloadConfig() (*config.Config, error) {
	d.mu.Lock()
	configPath := d.configPath
	loader := d.configLoader
	d.mu.Unlock()

	if configPath == "" {
		return nil, errors.New("config path is not set")
	}

	cfg, err := loader(configPath)
	if err != nil {
		return nil, err
	}

	d.mu.Lock()
	d.cfg = cfg
	d.mu.Unlock()
	return cfg, nil
}

func (d *Daemon) snapshot() statusResponse {
	d.mu.Lock()
	defer d.mu.Unlock()

	resp := statusResponse{
		State:     d.status.State,
		LastError: d.status.LastError,
	}
	if !d.status.LastBackupAt.IsZero() {
		resp.LastBackupAt = d.status.LastBackupAt.Format(time.RFC3339)
	}
	if !d.status.NextScheduledAt.IsZero() {
		resp.NextScheduledAt = d.status.NextScheduledAt.Format(time.RFC3339)
	}
	if !d.status.LastRestoreAt.IsZero() {
		resp.LastRestoreAt = d.status.LastRestoreAt.Format(time.RFC3339)
	}
	if d.status.LastRestorePath != "" {
		resp.LastRestorePath = d.status.LastRestorePath
	}
	if d.status.LastRestoreError != "" {
		resp.LastRestoreError = d.status.LastRestoreError
	}
	return resp
}
