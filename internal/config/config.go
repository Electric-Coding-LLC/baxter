package config

import (
	"errors"
	"os"
)

type Config struct {
	BackupRoots []string        `toml:"backup_roots"`
	Schedule    string          `toml:"schedule"`
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
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return DefaultConfig(), nil
		}
		return nil, err
	}

	return nil, errors.New("TOML parsing not implemented yet")
}
