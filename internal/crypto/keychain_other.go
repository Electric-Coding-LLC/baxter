//go:build !darwin

package crypto

import "fmt"

func PassphraseFromKeychain(service, account string) (string, error) {
	return "", fmt.Errorf("keychain access is only supported on macOS")
}
