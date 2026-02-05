package config

import (
	"errors"
	"os"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	BackupRoots []string         `toml:"backup_roots"`
	Schedule    string           `toml:"schedule"`
	S3          S3Config         `toml:"s3"`
	Encryption  EncryptionConfig `toml:"encryption"`
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

func DefaultConfig() *Config {
	return &Config{
		BackupRoots: []string{},
		Schedule:    "daily",
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
	if c.Schedule == "" {
		c.Schedule = "daily"
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
}

func (c *Config) Normalize() {
	if c.S3.Prefix != "" && !strings.HasSuffix(c.S3.Prefix, "/") {
		c.S3.Prefix += "/"
	}
}

func (c *Config) Validate() error {
	switch c.Schedule {
	case "", "daily", "weekly", "manual":
		// valid
	default:
		return errors.New("schedule must be daily, weekly, or manual")
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
	return nil
}
