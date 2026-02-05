package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"baxter/internal/backup"
	"baxter/internal/config"
)

const appName = "baxter"

type Daemon struct {
	cfg *config.Config
}

func New(cfg *config.Config) *Daemon {
	return &Daemon{cfg: cfg}
}

func (d *Daemon) Run(ctx context.Context) error {
	_ = ctx
	fmt.Println("baxterd starting")

	if len(d.cfg.BackupRoots) == 0 {
		fmt.Println("no backup roots configured; exiting")
		return nil
	}

	manifestPath, err := stateManifestPath()
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

func stateManifestPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			return "", homeErr
		}
		dir = filepath.Join(home, "Library", "Application Support")
	}

	return filepath.Join(dir, appName, "manifest.json"), nil
}
