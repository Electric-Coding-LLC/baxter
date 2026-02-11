package cli

import (
	"errors"
	"flag"
	"os"
)

func parseRestoreArgs(args []string) (restoreOptions, string, error) {
	restoreFS := flag.NewFlagSet("restore", flag.ContinueOnError)
	restoreFS.SetOutput(os.Stderr)

	var opts restoreOptions
	restoreFS.BoolVar(&opts.DryRun, "dry-run", false, "show what would be restored without writing files")
	restoreFS.StringVar(&opts.ToDir, "to", "", "destination root directory for restore")
	restoreFS.BoolVar(&opts.Overwrite, "overwrite", false, "overwrite existing target files")
	restoreFS.BoolVar(&opts.VerifyOnly, "verify-only", false, "verify restore content checksum without writing files")
	restoreFS.StringVar(&opts.Snapshot, "snapshot", "", "restore from snapshot selector (latest, snapshot id, or RFC3339 timestamp)")

	if err := restoreFS.Parse(args); err != nil {
		return restoreOptions{}, "", err
	}

	rest := restoreFS.Args()
	if len(rest) != 1 {
		return restoreOptions{}, "", errors.New("usage: baxter restore [--dry-run] [--verify-only] [--to dir] [--overwrite] [--snapshot latest|id|RFC3339] <path>")
	}
	if opts.DryRun && opts.VerifyOnly {
		return restoreOptions{}, "", errors.New("restore --dry-run and --verify-only cannot be used together")
	}
	return opts, rest[0], nil
}

func parseRestoreListArgs(args []string) (restoreListOptions, error) {
	listFS := flag.NewFlagSet("restore list", flag.ContinueOnError)
	listFS.SetOutput(os.Stderr)

	var opts restoreListOptions
	listFS.StringVar(&opts.Prefix, "prefix", "", "filter restore paths by prefix")
	listFS.StringVar(&opts.Contains, "contains", "", "filter restore paths containing text")
	listFS.StringVar(&opts.Snapshot, "snapshot", "", "list paths from snapshot selector (latest, snapshot id, or RFC3339 timestamp)")

	if err := listFS.Parse(args); err != nil {
		return restoreListOptions{}, err
	}
	if len(listFS.Args()) != 0 {
		return restoreListOptions{}, errors.New("usage: baxter restore list [--snapshot latest|id|RFC3339] [--prefix path] [--contains text]")
	}
	return opts, nil
}

func parseSnapshotListArgs(args []string) (snapshotListOptions, error) {
	listFS := flag.NewFlagSet("snapshot list", flag.ContinueOnError)
	listFS.SetOutput(os.Stderr)

	var opts snapshotListOptions
	listFS.IntVar(&opts.Limit, "limit", 20, "maximum number of snapshots to show (0 for all)")

	if err := listFS.Parse(args); err != nil {
		return snapshotListOptions{}, err
	}
	if len(listFS.Args()) != 0 {
		return snapshotListOptions{}, errors.New("usage: baxter snapshot list [--limit n]")
	}
	if opts.Limit < 0 {
		return snapshotListOptions{}, errors.New("limit must be >= 0")
	}
	return opts, nil
}

func parseGCArgs(args []string) (gcOptions, error) {
	gcFS := flag.NewFlagSet("gc", flag.ContinueOnError)
	gcFS.SetOutput(os.Stderr)

	var opts gcOptions
	gcFS.BoolVar(&opts.DryRun, "dry-run", false, "show object deletions without deleting")

	if err := gcFS.Parse(args); err != nil {
		return gcOptions{}, err
	}
	if len(gcFS.Args()) != 0 {
		return gcOptions{}, errors.New("usage: baxter gc [--dry-run]")
	}
	return opts, nil
}

func parseVerifyArgs(args []string) (verifyOptions, error) {
	verifyFS := flag.NewFlagSet("verify", flag.ContinueOnError)
	verifyFS.SetOutput(os.Stderr)

	var opts verifyOptions
	verifyFS.StringVar(&opts.Snapshot, "snapshot", "", "verify from snapshot selector (latest, snapshot id, or RFC3339 timestamp)")
	verifyFS.StringVar(&opts.Prefix, "prefix", "", "verify only paths with this prefix")
	verifyFS.IntVar(&opts.Limit, "limit", 0, "maximum entries to verify after filtering (0 for all)")
	verifyFS.IntVar(&opts.Sample, "sample", 0, "sample size before limit is applied (0 for all)")

	if err := verifyFS.Parse(args); err != nil {
		return verifyOptions{}, err
	}
	if len(verifyFS.Args()) != 0 {
		return verifyOptions{}, errors.New("usage: baxter verify [--snapshot latest|id|RFC3339] [--prefix path] [--limit n] [--sample n]")
	}
	if opts.Limit < 0 {
		return verifyOptions{}, errors.New("limit must be >= 0")
	}
	if opts.Sample < 0 {
		return verifyOptions{}, errors.New("sample must be >= 0")
	}
	return opts, nil
}
