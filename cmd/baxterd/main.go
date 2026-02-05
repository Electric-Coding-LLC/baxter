package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"baxter/internal/config"
	"baxter/internal/daemon"
)

const appName = "baxter"

func defaultConfigDir() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "Application Support", appName)
	}
	return filepath.Join(dir, appName)
}

func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "", "path to config file")
	flag.Parse()

	if configPath == "" {
		configPath = filepath.Join(defaultConfigDir(), "config.toml")
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	d := daemon.New(cfg)
	if err := d.Run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "daemon error: %v\n", err)
		os.Exit(1)
	}
}
