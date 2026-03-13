package storage

import (
	"errors"
	"strings"
)

func normalizeListKeyPrefix(prefix string) (string, error) {
	normalized := strings.TrimSpace(strings.ReplaceAll(prefix, "\\", "/"))
	if normalized == "" {
		return "", nil
	}
	if strings.HasPrefix(normalized, "/") {
		return "", errors.New("invalid object key prefix")
	}

	keepTrailingSlash := strings.HasSuffix(normalized, "/")
	parts := strings.Split(normalized, "/")
	cleanParts := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		if part == "." || part == ".." {
			return "", errors.New("invalid object key prefix")
		}
		cleanParts = append(cleanParts, part)
	}
	if len(cleanParts) == 0 {
		return "", errors.New("invalid object key prefix")
	}

	normalized = strings.Join(cleanParts, "/")
	if keepTrailingSlash {
		normalized += "/"
	}
	return normalized, nil
}
