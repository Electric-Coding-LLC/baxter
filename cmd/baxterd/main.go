package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"baxter/internal/config"
	"baxter/internal/daemon"
	"baxter/internal/state"
)

func main() {
	var configPath string
	var runOnce bool
	var ipcAddr string
	var allowRemoteIPC bool
	var ipcToken string
	defaultConfigPath, err := state.ConfigPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "state path error: %v\n", err)
		os.Exit(1)
	}

	flag.StringVar(&configPath, "config", defaultConfigPath, "path to config file")
	flag.BoolVar(&runOnce, "once", false, "run one backup pass and exit")
	flag.StringVar(&ipcAddr, "ipc-addr", daemon.DefaultIPCAddress, "daemon IPC listen address")
	flag.BoolVar(&allowRemoteIPC, "allow-remote-ipc", false, "allow non-loopback IPC listeners (disabled by default for safety)")
	flag.StringVar(&ipcToken, "ipc-token", "", "shared secret token required by state-changing IPC endpoints")
	flag.Parse()

	ipcAddr, err = daemon.ValidateIPCAddress(ipcAddr, allowRemoteIPC)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ipc address error: %v\n", err)
		os.Exit(1)
	}

	if ipcToken == "" {
		ipcToken = strings.TrimSpace(os.Getenv("BAXTER_IPC_TOKEN"))
	}
	if allowRemoteIPC && ipcToken == "" {
		fmt.Fprintln(os.Stderr, "ipc token error: --allow-remote-ipc requires --ipc-token or BAXTER_IPC_TOKEN")
		os.Exit(1)
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	d := daemon.New(cfg)
	d.SetIPCAddress(ipcAddr)
	d.SetIPCAuthToken(ipcToken)
	d.SetConfigPath(configPath)

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
