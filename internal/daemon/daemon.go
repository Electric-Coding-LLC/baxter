package daemon

import (
	"context"
	"fmt"

	"baxter/internal/config"
)

type Daemon struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Daemon {
	return &Daemon{cfg: cfg}
}

func (d *Daemon) Run(ctx context.Context) error {
	_ = ctx
	fmt.Println("baxterd starting")
	// TODO: schedule backups, watch filesystem, and run incremental uploads.
	return nil
}
