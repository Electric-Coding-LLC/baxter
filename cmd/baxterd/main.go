package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"baxter/internal/config"
	"baxter/internal/daemon"
	"baxter/internal/state"
)

func main() {
	var configPath string
	defaultConfigPath, err := state.ConfigPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "state path error: %v\n", err)
		os.Exit(1)
	}

	flag.StringVar(&configPath, "config", defaultConfigPath, "path to config file")
	flag.Parse()

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
