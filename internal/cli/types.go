package cli

const passphraseEnv = "BAXTER_PASSPHRASE"

type restoreOptions struct {
	DryRun     bool
	ToDir      string
	Overwrite  bool
	VerifyOnly bool
	Snapshot   string
}

type restoreListOptions struct {
	Prefix   string
	Contains string
	Snapshot string
}

type snapshotListOptions struct {
	Limit int
}

type gcOptions struct {
	DryRun bool
}

type verifyOptions struct {
	Snapshot string
	Prefix   string
	Limit    int
	Sample   int
}
