package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	BackupRoots  []string         `toml:"backup_roots"`
	ExcludePaths []string         `toml:"exclude_paths"`
	ExcludeGlobs []string         `toml:"exclude_globs"`
	Schedule     string           `toml:"schedule"`
	DailyTime    string           `toml:"daily_time"`
	WeeklyDay    string           `toml:"weekly_day"`
	WeeklyTime   string           `toml:"weekly_time"`
	S3           S3Config         `toml:"s3"`
	Encryption   EncryptionConfig `toml:"encryption"`
	Retention    RetentionConfig  `toml:"retention"`
	Verify       VerifyConfig     `toml:"verify"`
}

type S3Config struct {
	Endpoint string `toml:"endpoint"`
	Region   string `toml:"region"`
	Bucket   string `toml:"bucket"`
	Prefix   string `toml:"prefix"`
}

type EncryptionConfig struct {
	KeychainService string `toml:"keychain_service"`
	KeychainAccount string `toml:"keychain_account"`
}

type RetentionConfig struct {
	ManifestSnapshots int `toml:"manifest_snapshots"`
}

type VerifyConfig struct {
	Schedule   string `toml:"schedule"`
	DailyTime  string `toml:"daily_time"`
	WeeklyDay  string `toml:"weekly_day"`
	WeeklyTime string `toml:"weekly_time"`
	Prefix     string `toml:"prefix"`
	Limit      int    `toml:"limit"`
	Sample     int    `toml:"sample"`
}

func DefaultConfig() *Config {
	return &Config{
		BackupRoots:  []string{},
		ExcludePaths: []string{},
		ExcludeGlobs: []string{},
		Schedule:     "daily",
		DailyTime:    "09:00",
		WeeklyDay:    "sunday",
		WeeklyTime:   "09:00",
		S3: S3Config{
			Endpoint: "",
			Region:   "",
			Bucket:   "",
			Prefix:   "baxter/",
		},
		Encryption: EncryptionConfig{
			KeychainService: "baxter",
			KeychainAccount: "default",
		},
		Retention: RetentionConfig{
			ManifestSnapshots: 30,
		},
		Verify: VerifyConfig{
			Schedule:   "manual",
			DailyTime:  "09:00",
			WeeklyDay:  "sunday",
			WeeklyTime: "09:00",
			Prefix:     "",
			Limit:      0,
			Sample:     0,
		},
	}
}

func Load(path string) (*Config, error) {
	cfg := DefaultConfig()

	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, err
	}

	if _, err := toml.DecodeFile(path, cfg); err != nil {
		return nil, err
	}

	cfg.ApplyDefaults()
	cfg.Normalize()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

func (c *Config) ApplyDefaults() {
	if len(c.BackupRoots) == 0 {
		c.BackupRoots = []string{}
	}
	if len(c.ExcludePaths) == 0 {
		c.ExcludePaths = []string{}
	}
	if len(c.ExcludeGlobs) == 0 {
		c.ExcludeGlobs = []string{}
	}
	if c.Schedule == "" {
		c.Schedule = "daily"
	}
	if c.DailyTime == "" {
		c.DailyTime = "09:00"
	}
	if c.WeeklyDay == "" {
		c.WeeklyDay = "sunday"
	}
	if c.WeeklyTime == "" {
		c.WeeklyTime = "09:00"
	}
	if c.S3.Prefix == "" {
		c.S3.Prefix = "baxter/"
	}
	if c.Encryption.KeychainService == "" {
		c.Encryption.KeychainService = "baxter"
	}
	if c.Encryption.KeychainAccount == "" {
		c.Encryption.KeychainAccount = "default"
	}
	if c.Verify.Schedule == "" {
		c.Verify.Schedule = "manual"
	}
	if c.Verify.DailyTime == "" {
		c.Verify.DailyTime = "09:00"
	}
	if c.Verify.WeeklyDay == "" {
		c.Verify.WeeklyDay = "sunday"
	}
	if c.Verify.WeeklyTime == "" {
		c.Verify.WeeklyTime = "09:00"
	}
}

func (c *Config) Normalize() {
	c.Schedule = strings.ToLower(strings.TrimSpace(c.Schedule))
	c.DailyTime = strings.TrimSpace(c.DailyTime)
	c.WeeklyDay = strings.ToLower(strings.TrimSpace(c.WeeklyDay))
	c.WeeklyTime = strings.TrimSpace(c.WeeklyTime)

	for i, root := range c.BackupRoots {
		trimmed := strings.TrimSpace(root)
		if trimmed == "" {
			c.BackupRoots[i] = ""
			continue
		}
		c.BackupRoots[i] = filepath.Clean(trimmed)
	}

	for i, path := range c.ExcludePaths {
		trimmed := strings.TrimSpace(path)
		if trimmed == "" {
			c.ExcludePaths[i] = ""
			continue
		}
		c.ExcludePaths[i] = filepath.Clean(trimmed)
	}

	for i, pattern := range c.ExcludeGlobs {
		c.ExcludeGlobs[i] = strings.TrimSpace(pattern)
	}

	if c.S3.Prefix != "" && !strings.HasSuffix(c.S3.Prefix, "/") {
		c.S3.Prefix += "/"
	}

	c.Verify.Schedule = strings.ToLower(strings.TrimSpace(c.Verify.Schedule))
	c.Verify.DailyTime = strings.TrimSpace(c.Verify.DailyTime)
	c.Verify.WeeklyDay = strings.ToLower(strings.TrimSpace(c.Verify.WeeklyDay))
	c.Verify.WeeklyTime = strings.TrimSpace(c.Verify.WeeklyTime)
	c.Verify.Prefix = strings.TrimSpace(c.Verify.Prefix)
}

func (c *Config) Validate() error {
	switch c.Schedule {
	case "", "daily", "weekly", "manual":
		// valid
	default:
		return errors.New("schedule must be daily, weekly, or manual")
	}
	if c.Schedule == "daily" {
		if c.DailyTime == "" {
			return errors.New("daily_time is required when schedule is daily")
		}
		if !isValidHHMM(c.DailyTime) {
			return errors.New("daily_time must be in HH:MM (24-hour) format")
		}
	}
	if c.Schedule == "weekly" {
		if c.WeeklyDay == "" {
			return errors.New("weekly_day is required when schedule is weekly")
		}
		if !isValidWeekday(c.WeeklyDay) {
			return errors.New("weekly_day must be one of: sunday,monday,tuesday,wednesday,thursday,friday,saturday")
		}
		if c.WeeklyTime == "" {
			return errors.New("weekly_time is required when schedule is weekly")
		}
		if !isValidHHMM(c.WeeklyTime) {
			return errors.New("weekly_time must be in HH:MM (24-hour) format")
		}
	}

	for i, root := range c.BackupRoots {
		if strings.TrimSpace(root) == "" {
			return fmt.Errorf("backup_roots[%d] must not be empty", i)
		}
		if !filepath.IsAbs(root) {
			return fmt.Errorf("backup_roots[%d] must be an absolute path", i)
		}
	}
	for i, path := range c.ExcludePaths {
		if strings.TrimSpace(path) == "" {
			return fmt.Errorf("exclude_paths[%d] must not be empty", i)
		}
		if !filepath.IsAbs(path) {
			return fmt.Errorf("exclude_paths[%d] must be an absolute path", i)
		}
	}
	for i, pattern := range c.ExcludeGlobs {
		if strings.TrimSpace(pattern) == "" {
			return fmt.Errorf("exclude_globs[%d] must not be empty", i)
		}
		if _, err := filepath.Match(pattern, "example"); err != nil {
			return fmt.Errorf("exclude_globs[%d] invalid pattern: %v", i, err)
		}
	}

	if c.S3.Bucket == "" {
		if c.S3.Region != "" || c.S3.Endpoint != "" {
			return errors.New("s3.bucket is required when s3.region or s3.endpoint is set")
		}
	} else {
		if c.S3.Region == "" {
			return errors.New("s3.region is required when s3.bucket is set")
		}
		if strings.Contains(c.S3.Bucket, "/") {
			return errors.New("s3.bucket must not contain '/'")
		}
		if c.S3.Prefix == "" {
			return errors.New("s3.prefix must not be empty")
		}
	}

	if strings.TrimSpace(c.Encryption.KeychainService) == "" {
		return errors.New("encryption.keychain_service must not be empty")
	}
	if strings.TrimSpace(c.Encryption.KeychainAccount) == "" {
		return errors.New("encryption.keychain_account must not be empty")
	}
	if c.Retention.ManifestSnapshots < 0 {
		return errors.New("retention.manifest_snapshots must be >= 0")
	}
	switch c.Verify.Schedule {
	case "", "daily", "weekly", "manual":
		// valid
	default:
		return errors.New("verify.schedule must be daily, weekly, or manual")
	}
	if c.Verify.Schedule == "daily" {
		if c.Verify.DailyTime == "" {
			return errors.New("verify.daily_time is required when verify.schedule is daily")
		}
		if !isValidHHMM(c.Verify.DailyTime) {
			return errors.New("verify.daily_time must be in HH:MM (24-hour) format")
		}
	}
	if c.Verify.Schedule == "weekly" {
		if c.Verify.WeeklyDay == "" {
			return errors.New("verify.weekly_day is required when verify.schedule is weekly")
		}
		if !isValidWeekday(c.Verify.WeeklyDay) {
			return errors.New("verify.weekly_day must be one of: sunday,monday,tuesday,wednesday,thursday,friday,saturday")
		}
		if c.Verify.WeeklyTime == "" {
			return errors.New("verify.weekly_time is required when verify.schedule is weekly")
		}
		if !isValidHHMM(c.Verify.WeeklyTime) {
			return errors.New("verify.weekly_time must be in HH:MM (24-hour) format")
		}
	}
	if c.Verify.Limit < 0 {
		return errors.New("verify.limit must be >= 0")
	}
	if c.Verify.Sample < 0 {
		return errors.New("verify.sample must be >= 0")
	}
	return nil
}

func isValidHHMM(value string) bool {
	if len(value) != 5 || value[2] != ':' {
		return false
	}
	hour := value[0:2]
	minute := value[3:5]
	if hour[0] < '0' || hour[0] > '2' || hour[1] < '0' || hour[1] > '9' {
		return false
	}
	if minute[0] < '0' || minute[0] > '5' || minute[1] < '0' || minute[1] > '9' {
		return false
	}
	h := int(hour[0]-'0')*10 + int(hour[1]-'0')
	return h >= 0 && h <= 23
}

func isValidWeekday(value string) bool {
	switch value {
	case "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday":
		return true
	default:
		return false
	}
}
