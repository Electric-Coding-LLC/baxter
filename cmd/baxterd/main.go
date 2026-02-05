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
	var runOnce bool
	var ipcAddr string
	defaultConfigPath, err := state.ConfigPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "state path error: %v\n", err)
		os.Exit(1)
	}

	flag.StringVar(&configPath, "config", defaultConfigPath, "path to config file")
	flag.BoolVar(&runOnce, "once", false, "run one backup pass and exit")
	flag.StringVar(&ipcAddr, "ipc-addr", daemon.DefaultIPCAddress, "daemon IPC listen address")
	flag.Parse()

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	d := daemon.New(cfg)
	d.SetIPCAddress(ipcAddr)

	var runErr error
	if runOnce {
		runErr = d.RunOnce(context.Background())
	} else {
		runErr = d.Run(context.Background())
	}
	if runErr != nil {
		fmt.Fprintf(os.Stderr, "daemon error: %v\n", runErr)
		os.Exit(1)
	}
}
