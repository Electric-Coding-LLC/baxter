//go:build darwin

package crypto

import (
	"fmt"
	"os/exec"
	"strings"
)

func PassphraseFromKeychain(service, account string) (string, error) {
	if strings.TrimSpace(service) == "" {
		return "", fmt.Errorf("keychain service is required")
	}
	if strings.TrimSpace(account) == "" {
		return "", fmt.Errorf("keychain account is required")
	}

	cmd := exec.Command("security", "find-generic-password", "-s", service, "-a", account, "-w")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("read keychain item %q/%q: %w", service, account, err)
	}

	passphrase := strings.TrimSpace(string(out))
	if passphrase == "" {
		return "", fmt.Errorf("keychain item %q/%q is empty", service, account)
	}
	return passphrase, nil
}
