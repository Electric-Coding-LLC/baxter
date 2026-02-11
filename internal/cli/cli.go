package cli

import (
	"baxter/internal/config"
	"baxter/internal/state"
	"errors"
	"flag"
	"fmt"
	"os"
)

func Run(args []string) error {
	fs := flag.NewFlagSet("baxter", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	configPath, err := state.ConfigPath()
	if err != nil {
		return err
	}
	fs.StringVar(&configPath, "config", configPath, "path to config file")

	if err := fs.Parse(args); err != nil {
		return err
	}

	rest := fs.Args()
	if len(rest) == 0 {
		return usageError()
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	switch rest[0] {
	case "backup":
		if len(rest) < 2 {
			return errors.New("missing backup subcommand (run|status)")
		}
		switch rest[1] {
		case "run":
			return runBackup(cfg)
		case "status":
			return backupStatus(cfg)
		default:
			return errors.New("unknown backup subcommand")
		}
	case "restore":
		if len(rest) >= 2 && rest[1] == "list" {
			opts, err := parseRestoreListArgs(rest[2:])
			if err != nil {
				return err
			}
			return restoreList(opts)
		}

		opts, restorePathArg, err := parseRestoreArgs(rest[1:])
		if err != nil {
			return err
		}
		return restorePath(cfg, restorePathArg, opts)
	case "snapshot":
		if len(rest) < 2 || rest[1] != "list" {
			return errors.New("unknown snapshot subcommand")
		}
		opts, err := parseSnapshotListArgs(rest[2:])
		if err != nil {
			return err
		}
		return snapshotList(opts)
	case "gc":
		opts, err := parseGCArgs(rest[1:])
		if err != nil {
			return err
		}
		return runGC(cfg, opts)
	case "verify":
		opts, err := parseVerifyArgs(rest[1:])
		if err != nil {
			return err
		}
		return runVerify(cfg, opts)
	default:
		return usageError()
	}
}

func usageError() error {
	return errors.New("usage: baxter [-config path] backup run|status | snapshot list [--limit n] | gc [--dry-run] | verify [--snapshot latest|id|RFC3339] [--prefix path] [--limit n] [--sample n] | restore list [--snapshot latest|id|RFC3339] [--prefix path] [--contains text] | restore [--dry-run] [--verify-only] [--to dir] [--overwrite] [--snapshot latest|id|RFC3339] <path>")
}
