package recovery

import (
	"fmt"
	"strings"

	"baxter/internal/config"
)

func BackupSetID(cfg *config.Config) string {
	if cfg == nil {
		return "local"
	}

	bucket := strings.TrimSpace(cfg.S3.Bucket)
	if bucket == "" {
		return "local"
	}

	prefix := strings.Trim(strings.TrimSpace(cfg.S3.Prefix), "/")
	if prefix == "" {
		return fmt.Sprintf("s3://%s", bucket)
	}
	return fmt.Sprintf("s3://%s/%s", bucket, prefix)
}
