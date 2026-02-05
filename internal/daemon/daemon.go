package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

const DefaultIPCAddress = "127.0.0.1:41820"

type daemonStatus struct {
	State        string
	LastBackupAt time.Time
	LastError    string
}

type statusResponse struct {
	State        string `json:"state"`
	LastBackupAt string `json:"last_backup_at,omitempty"`
	LastError    string `json:"last_error,omitempty"`
}

type Daemon struct {
	cfg     *config.Config
	ipcAddr string
	mu      sync.Mutex
	running bool
	status  daemonStatus
	handler http.Handler
}

func New(cfg *config.Config) *Daemon {
	d := &Daemon{
		cfg:     cfg,
		ipcAddr: DefaultIPCAddress,
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

	err := srv.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func (d *Daemon) RunOnce(ctx context.Context) error {
	if err := d.performBackup(ctx); err != nil {
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

func (d *Daemon) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

var errBackupAlreadyRunning = errors.New("backup already running")

func (d *Daemon) triggerBackup() error {
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
		err := d.performBackup(context.Background())
		if err != nil {
			d.setFailed(err)
			return
		}
		d.setIdleSuccess()
	}()
	return nil
}

func (d *Daemon) performBackup(ctx context.Context) error {
	_ = ctx
	if len(d.cfg.BackupRoots) == 0 {
		return errors.New("no backup roots configured")
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	previous, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}

	current, err := backup.BuildManifest(d.cfg.BackupRoots)
	if err != nil {
		return fmt.Errorf("build manifest: %w", err)
	}

	plan := backup.PlanChanges(previous, current)
	fmt.Printf("planned upload changes=%d removed=%d\n", len(plan.NewOrChanged), len(plan.RemovedPaths))

	if err := backup.SaveManifest(manifestPath, current); err != nil {
		return fmt.Errorf("save manifest: %w", err)
	}
	return nil
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
	return resp
}
