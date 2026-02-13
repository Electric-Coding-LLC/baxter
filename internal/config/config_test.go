package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadMissingFileReturnsDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.toml")

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("load missing file: %v", err)
	}

	if cfg.Schedule != "daily" {
		t.Fatalf("unexpected default schedule: got %q want %q", cfg.Schedule, "daily")
	}
	if len(cfg.ExcludePaths) != 0 {
		t.Fatalf("unexpected default exclude_paths: got %#v want empty", cfg.ExcludePaths)
	}
	if len(cfg.ExcludeGlobs) != 0 {
		t.Fatalf("unexpected default exclude_globs: got %#v want empty", cfg.ExcludeGlobs)
	}
	if cfg.DailyTime != "09:00" {
		t.Fatalf("unexpected default daily_time: got %q want %q", cfg.DailyTime, "09:00")
	}
	if cfg.WeeklyDay != "sunday" {
		t.Fatalf("unexpected default weekly_day: got %q want %q", cfg.WeeklyDay, "sunday")
	}
	if cfg.WeeklyTime != "09:00" {
		t.Fatalf("unexpected default weekly_time: got %q want %q", cfg.WeeklyTime, "09:00")
	}
	if cfg.S3.Prefix != "baxter/" {
		t.Fatalf("unexpected default s3 prefix: got %q want %q", cfg.S3.Prefix, "baxter/")
	}
	if cfg.Encryption.KeychainService != "baxter" {
		t.Fatalf("unexpected keychain service: got %q want %q", cfg.Encryption.KeychainService, "baxter")
	}
	if cfg.Encryption.KeychainAccount != "default" {
		t.Fatalf("unexpected keychain account: got %q want %q", cfg.Encryption.KeychainAccount, "default")
	}
	if cfg.Verify.Schedule != "manual" {
		t.Fatalf("unexpected default verify schedule: got %q want %q", cfg.Verify.Schedule, "manual")
	}
	if cfg.Verify.DailyTime != "09:00" {
		t.Fatalf("unexpected default verify daily_time: got %q want %q", cfg.Verify.DailyTime, "09:00")
	}
	if cfg.Verify.WeeklyDay != "sunday" {
		t.Fatalf("unexpected default verify weekly_day: got %q want %q", cfg.Verify.WeeklyDay, "sunday")
	}
	if cfg.Verify.WeeklyTime != "09:00" {
		t.Fatalf("unexpected default verify weekly_time: got %q want %q", cfg.Verify.WeeklyTime, "09:00")
	}
}

func TestLoadAppliesDefaultsAndNormalizes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	content := strings.Join([]string{
		"backup_roots = [\" /Users/test/Documents/../Pictures \"]",
		"exclude_paths = [\" /Users/test/Documents/Downloads \", \" /Users/test/Documents/Downloads \"]",
		"exclude_globs = [\" *.tmp \", \" *.tmp \", \" .DS_Store \"]",
		"schedule = \"manual\"",
		"daily_time = \" 07:30 \"",
		"weekly_day = \" MONDAY \"",
		"weekly_time = \" 18:45 \"",
		"",
		"[s3]",
		"bucket = \"example-bucket\"",
		"region = \"us-east-1\"",
		"prefix = \"custom\"",
		"",
		"[encryption]",
		"keychain_service = \"\"",
		"keychain_account = \"\"",
		"",
		"[verify]",
		"schedule = \" WEEKLY \"",
		"weekly_day = \" MONDAY \"",
		"weekly_time = \" 06:45 \"",
		"prefix = \" /Users/test/Documents \"",
		"limit = 25",
		"sample = 5",
	}, "\n")

	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.S3.Prefix != "custom/" {
		t.Fatalf("expected normalized prefix: got %q want %q", cfg.S3.Prefix, "custom/")
	}
	if cfg.DailyTime != "07:30" {
		t.Fatalf("expected normalized daily_time: got %q", cfg.DailyTime)
	}
	if cfg.WeeklyDay != "monday" {
		t.Fatalf("expected normalized weekly_day: got %q", cfg.WeeklyDay)
	}
	if cfg.WeeklyTime != "18:45" {
		t.Fatalf("expected normalized weekly_time: got %q", cfg.WeeklyTime)
	}
	if len(cfg.BackupRoots) != 1 || cfg.BackupRoots[0] != "/Users/test/Pictures" {
		t.Fatalf("expected normalized backup root: got %#v", cfg.BackupRoots)
	}
	if len(cfg.ExcludePaths) != 2 || cfg.ExcludePaths[0] != "/Users/test/Documents/Downloads" || cfg.ExcludePaths[1] != "/Users/test/Documents/Downloads" {
		t.Fatalf("expected normalized exclude_paths: got %#v", cfg.ExcludePaths)
	}
	if len(cfg.ExcludeGlobs) != 3 || cfg.ExcludeGlobs[0] != "*.tmp" || cfg.ExcludeGlobs[1] != "*.tmp" || cfg.ExcludeGlobs[2] != ".DS_Store" {
		t.Fatalf("expected normalized exclude_globs: got %#v", cfg.ExcludeGlobs)
	}
	if cfg.Encryption.KeychainService != "baxter" {
		t.Fatalf("expected default keychain service: got %q want %q", cfg.Encryption.KeychainService, "baxter")
	}
	if cfg.Encryption.KeychainAccount != "default" {
		t.Fatalf("expected default keychain account: got %q want %q", cfg.Encryption.KeychainAccount, "default")
	}
	if cfg.Verify.Schedule != "weekly" {
		t.Fatalf("expected normalized verify.schedule: got %q", cfg.Verify.Schedule)
	}
	if cfg.Verify.WeeklyDay != "monday" {
		t.Fatalf("expected normalized verify.weekly_day: got %q", cfg.Verify.WeeklyDay)
	}
	if cfg.Verify.WeeklyTime != "06:45" {
		t.Fatalf("expected normalized verify.weekly_time: got %q", cfg.Verify.WeeklyTime)
	}
	if cfg.Verify.Prefix != "/Users/test/Documents" {
		t.Fatalf("expected normalized verify.prefix: got %q", cfg.Verify.Prefix)
	}
	if cfg.Verify.Limit != 25 {
		t.Fatalf("expected verify.limit=25, got %d", cfg.Verify.Limit)
	}
	if cfg.Verify.Sample != 5 {
		t.Fatalf("expected verify.sample=5, got %d", cfg.Verify.Sample)
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr string
	}{
		{
			name: "valid local storage with manual schedule",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "manual",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
		},
		{
			name: "valid s3 storage",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "weekly",
				DailyTime:   "09:00",
				WeeklyDay:   "friday",
				WeeklyTime:  "18:15",
				S3: S3Config{
					Bucket: "my-bucket",
					Region: "us-west-2",
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
		},
		{
			name: "reject invalid schedule",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "hourly",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "schedule must be daily, weekly, or manual",
		},
		{
			name: "reject region without bucket",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Region: "us-east-1",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "s3.bucket is required when s3.region or s3.endpoint is set",
		},
		{
			name: "reject bucket without region",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Bucket: "my-bucket",
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "s3.region is required when s3.bucket is set",
		},
		{
			name: "reject bucket containing slash",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Bucket: "bad/bucket",
					Region: "us-east-1",
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "s3.bucket must not contain '/'",
		},
		{
			name: "reject empty prefix when bucket set",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Bucket: "my-bucket",
					Region: "us-east-1",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "s3.prefix must not be empty",
		},
		{
			name: "reject blank keychain service",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "  ",
					KeychainAccount: "acct",
				},
			},
			wantErr: "encryption.keychain_service must not be empty",
		},
		{
			name: "reject blank keychain account",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "  ",
				},
			},
			wantErr: "encryption.keychain_account must not be empty",
		},
		{
			name: "reject empty backup root",
			cfg: Config{
				BackupRoots: []string{""},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "backup_roots[0] must not be empty",
		},
		{
			name: "reject relative backup root",
			cfg: Config{
				BackupRoots: []string{"./Documents"},
				Schedule:    "daily",
				DailyTime:   "09:00",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "backup_roots[0] must be an absolute path",
		},
		{
			name: "reject invalid daily time",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "daily",
				DailyTime:   "9:15",
				WeeklyDay:   "sunday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "daily_time must be in HH:MM (24-hour) format",
		},
		{
			name: "reject empty exclude path",
			cfg: Config{
				BackupRoots:  []string{"/Users/me/Documents"},
				ExcludePaths: []string{""},
				Schedule:     "daily",
				DailyTime:    "09:00",
				WeeklyDay:    "sunday",
				WeeklyTime:   "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "exclude_paths[0] must not be empty",
		},
		{
			name: "reject relative exclude path",
			cfg: Config{
				BackupRoots:  []string{"/Users/me/Documents"},
				ExcludePaths: []string{"./Downloads"},
				Schedule:     "daily",
				DailyTime:    "09:00",
				WeeklyDay:    "sunday",
				WeeklyTime:   "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "exclude_paths[0] must be an absolute path",
		},
		{
			name: "reject empty exclude glob",
			cfg: Config{
				BackupRoots:  []string{"/Users/me/Documents"},
				ExcludeGlobs: []string{" "},
				Schedule:     "daily",
				DailyTime:    "09:00",
				WeeklyDay:    "sunday",
				WeeklyTime:   "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "exclude_globs[0] must not be empty",
		},
		{
			name: "reject invalid exclude glob pattern",
			cfg: Config{
				BackupRoots:  []string{"/Users/me/Documents"},
				ExcludeGlobs: []string{"["},
				Schedule:     "daily",
				DailyTime:    "09:00",
				WeeklyDay:    "sunday",
				WeeklyTime:   "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "exclude_globs[0] invalid pattern: syntax error in pattern",
		},
		{
			name: "reject missing weekly day",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "weekly",
				DailyTime:   "09:00",
				WeeklyDay:   "",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "weekly_day is required when schedule is weekly",
		},
		{
			name: "reject invalid weekly day",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "weekly",
				DailyTime:   "09:00",
				WeeklyDay:   "funday",
				WeeklyTime:  "09:00",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "weekly_day must be one of: sunday,monday,tuesday,wednesday,thursday,friday,saturday",
		},
		{
			name: "reject invalid weekly time",
			cfg: Config{
				BackupRoots: []string{"/Users/me/Documents"},
				Schedule:    "weekly",
				DailyTime:   "09:00",
				WeeklyDay:   "monday",
				WeeklyTime:  "24:30",
				S3: S3Config{
					Prefix: "baxter/",
				},
				Encryption: EncryptionConfig{
					KeychainService: "svc",
					KeychainAccount: "acct",
				},
			},
			wantErr: "weekly_time must be in HH:MM (24-hour) format",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			err := tc.cfg.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("validate returned unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error %q, got nil", tc.wantErr)
			}
			if err.Error() != tc.wantErr {
				t.Fatalf("unexpected error: got %q want %q", err.Error(), tc.wantErr)
			}
		})
	}
}

func TestValidateVerifyConfig(t *testing.T) {
	base := Config{
		BackupRoots: []string{"/Users/me/Documents"},
		Schedule:    "manual",
		DailyTime:   "09:00",
		WeeklyDay:   "sunday",
		WeeklyTime:  "09:00",
		S3: S3Config{
			Prefix: "baxter/",
		},
		Encryption: EncryptionConfig{
			KeychainService: "svc",
			KeychainAccount: "acct",
		},
	}

	t.Run("reject invalid verify schedule", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "hourly"
		if err := cfg.Validate(); err == nil || err.Error() != "verify.schedule must be daily, weekly, or manual" {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("reject invalid verify weekly day", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "weekly"
		cfg.Verify.WeeklyDay = "funday"
		cfg.Verify.WeeklyTime = "09:00"
		if err := cfg.Validate(); err == nil || err.Error() != "verify.weekly_day must be one of: sunday,monday,tuesday,wednesday,thursday,friday,saturday" {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("reject invalid verify weekly time", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "weekly"
		cfg.Verify.WeeklyDay = "monday"
		cfg.Verify.WeeklyTime = "24:00"
		if err := cfg.Validate(); err == nil || err.Error() != "verify.weekly_time must be in HH:MM (24-hour) format" {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("reject negative verify limit", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "manual"
		cfg.Verify.Limit = -1
		if err := cfg.Validate(); err == nil || err.Error() != "verify.limit must be >= 0" {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("reject negative verify sample", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "manual"
		cfg.Verify.Sample = -1
		if err := cfg.Validate(); err == nil || err.Error() != "verify.sample must be >= 0" {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("accept valid verify settings", func(t *testing.T) {
		cfg := base
		cfg.Verify.Schedule = "daily"
		cfg.Verify.DailyTime = "08:30"
		cfg.Verify.Prefix = "/Users/me/Documents"
		cfg.Verify.Limit = 100
		cfg.Verify.Sample = 10
		if err := cfg.Validate(); err != nil {
			t.Fatalf("validate returned unexpected error: %v", err)
		}
	})
}
