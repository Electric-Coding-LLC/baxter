package storage

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"

	"github.com/aws/smithy-go"
)

var ErrTransient = errors.New("transient storage error")

type httpStatusCodeProvider interface {
	HTTPStatusCode() int
}

func IsNotFound(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrNotExist) {
		return true
	}

	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch strings.ToLower(strings.TrimSpace(apiErr.ErrorCode())) {
		case "nosuchkey", "notfound", "nosuchbucket":
			return true
		}
	}
	return false
}

func IsTransient(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrTransient) {
		return true
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}

	var netErr net.Error
	if errors.As(err, &netErr) && (netErr.Timeout() || netErr.Temporary()) {
		return true
	}

	var statusErr httpStatusCodeProvider
	if errors.As(err, &statusErr) {
		statusCode := statusErr.HTTPStatusCode()
		if statusCode == 408 || statusCode == 429 || statusCode >= 500 {
			return true
		}
	}

	var apiErr smithy.APIError
	if errors.As(err, &apiErr) && isRetryableAWSCode(apiErr.ErrorCode()) {
		return true
	}

	return false
}

func isRetryableAWSCode(code string) bool {
	normalized := strings.ToLower(strings.TrimSpace(code))
	if normalized == "" {
		return false
	}
	switch normalized {
	case "requesttimeout", "requesttimeoutexception", "throttling", "throttlingexception", "slowdown", "internalerror", "serviceunavailable":
		return true
	}
	return strings.Contains(normalized, "timeout") ||
		strings.Contains(normalized, "throttl") ||
		strings.Contains(normalized, "unavailable") ||
		strings.Contains(normalized, "temporar")
}
