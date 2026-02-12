package daemon

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"baxter/internal/config"
)

const (
	serverReadHeaderTimeout = 5 * time.Second
	serverReadTimeout       = 10 * time.Second
	serverWriteTimeout      = 30 * time.Second
	serverIdleTimeout       = 60 * time.Second
	serverMaxHeaderBytes    = 1 << 20
)

type Daemon struct {
	cfg             *config.Config
	configPath      string
	ipcAuthToken    string
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

func (d *Daemon) SetIPCAuthToken(token string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.ipcAuthToken = token
}

func (d *Daemon) Handler() http.Handler {
	return d.handler
}

func (d *Daemon) Run(ctx context.Context) error {
	fmt.Printf("baxterd listening on %s\n", d.ipcAddr)

	srv := d.newHTTPServer()

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

func (d *Daemon) newHTTPServer() *http.Server {
	return &http.Server{
		Addr:              d.ipcAddr,
		Handler:           d.Handler(),
		ReadHeaderTimeout: serverReadHeaderTimeout,
		ReadTimeout:       serverReadTimeout,
		WriteTimeout:      serverWriteTimeout,
		IdleTimeout:       serverIdleTimeout,
		MaxHeaderBytes:    serverMaxHeaderBytes,
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
