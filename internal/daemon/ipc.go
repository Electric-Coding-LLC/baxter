package daemon

import (
	"fmt"
	"net"
	"strings"
)

// ValidateIPCAddress enforces secure-by-default IPC binding.
// Remote/non-loopback listeners require explicit opt-in.
func ValidateIPCAddress(addr string, allowRemote bool) (string, error) {
	trimmed := strings.TrimSpace(addr)
	if trimmed == "" {
		trimmed = DefaultIPCAddress
	}

	host, _, err := net.SplitHostPort(trimmed)
	if err != nil {
		return "", fmt.Errorf("invalid ipc address %q: %w", trimmed, err)
	}

	if allowRemote {
		return trimmed, nil
	}

	if strings.EqualFold(host, "localhost") {
		return trimmed, nil
	}

	ip := net.ParseIP(host)
	if ip == nil {
		return "", fmt.Errorf("ipc address %q is not loopback; pass --allow-remote-ipc to permit remote listeners", trimmed)
	}
	if !ip.IsLoopback() {
		return "", fmt.Errorf("ipc address %q is not loopback; pass --allow-remote-ipc to permit remote listeners", trimmed)
	}
	return trimmed, nil
}
