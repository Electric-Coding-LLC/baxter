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
	State           string
	LastBackupAt    time.Time
	NextScheduledAt time.Time
	LastError       string
}

type statusResponse struct {
	State           string `json:"state"`
	LastBackupAt    string `json:"last_backup_at,omitempty"`
	NextScheduledAt string `json:"next_scheduled_at,omitempty"`
	LastError       string `json:"last_error,omitempty"`
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

type Daemon struct {
	cfg             *config.Config
	configPath      string
	configLoader    func(string) (*config.Config, error)
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
		scheduleChanged: make(chan struct{}, 1),
		ipcAddr:         DefaultIPCAddress,
		status: daemonStatus{
			State: "idle",
		},
	}
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
		interval, enabled := d.scheduleInterval()
		if !enabled {
			d.setNextScheduledAt(time.Time{})
			select {
			case <-ctx.Done():
				return
			case <-d.scheduleChanged:
				continue
			}
		}

		nextRun := time.Now().Add(interval)
		d.setNextScheduledAt(nextRun)

		timer := time.NewTimer(time.Until(nextRun))
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-d.scheduleChanged:
			if !timer.Stop() {
				<-timer.C
			}
			continue
		case <-timer.C:
			if err := d.triggerBackup(); err != nil && !errors.Is(err, errBackupAlreadyRunning) {
				d.setFailed(err)
			}
		}
	}
}

func (d *Daemon) scheduleInterval() (time.Duration, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return scheduleInterval(d.cfg.Schedule)
}

func scheduleInterval(schedule string) (time.Duration, bool) {
	switch schedule {
	case "daily":
		return 24 * time.Hour, true
	case "weekly":
		return 7 * 24 * time.Hour, true
	default:
		return 0, false
	}
}

func (d *Daemon) RunOnce(ctx context.Context) error {
	if err := d.performBackup(ctx, d.currentConfig()); err != nil {
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
	return mux
}

func (d *Daemon) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	d.writeJSON(w, http.StatusOK, d.snapshot())
}

func (d *Daemon) handleRunBackup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if err := d.triggerBackup(); err != nil {
		if errors.Is(err, errBackupAlreadyRunning) {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	d.writeJSON(w, http.StatusAccepted, map[string]string{"status": "started"})
}

func (d *Daemon) handleReloadConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	_, err := d.reloadConfig()
	if err != nil {
		d.setLastError(fmt.Sprintf("config reload failed: %v", err))
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	d.setLastError("")
	d.notifyScheduleChanged()
	d.writeJSON(w, http.StatusOK, map[string]string{"status": "reloaded"})
}

func (d *Daemon) handleRestoreList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("load manifest: %v", err), http.StatusBadRequest)
		return
	}

	prefix := strings.TrimSpace(r.URL.Query().Get("prefix"))
	contains := strings.TrimSpace(r.URL.Query().Get("contains"))
	paths := filterRestorePaths(m.Entries, prefix, contains)
	d.writeJSON(w, http.StatusOK, restoreListResponse{Paths: paths})
}

func (d *Daemon) handleRestoreDryRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req restoreDryRunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, fmt.Sprintf("decode request: %v", err), http.StatusBadRequest)
		return
	}
	requestedPath := strings.TrimSpace(req.Path)
	if requestedPath == "" {
		http.Error(w, "path is required", http.StatusBadRequest)
		return
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("load manifest: %v", err), http.StatusBadRequest)
		return
	}

	entry, err := backup.FindEntryByPath(m, requestedPath)
	if err != nil {
		absPath, absErr := filepath.Abs(requestedPath)
		if absErr != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		entry, err = backup.FindEntryByPath(m, absPath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}

	targetPath, err := resolvedRestorePath(entry.Path, req.ToDir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	d.writeJSON(w, http.StatusOK, restoreDryRunResponse{
		SourcePath: entry.Path,
		TargetPath: targetPath,
		Overwrite:  req.Overwrite,
	})
}

func (d *Daemon) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
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
		err := d.performBackup(context.Background(), cfg)
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

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return err
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
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
	d.status.LastBackupAt = time.Now().UTC()
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
	return resp
}
