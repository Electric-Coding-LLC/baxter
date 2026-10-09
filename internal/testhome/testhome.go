// Package testhome gives a test process a private home directory so tests
// can never read or write the real Baxter state of the machine running them.
package testhome

import (
	"fmt"
	"os"
	"testing"
)

// Main runs m with HOME and XDG_CONFIG_HOME pointing at a fresh temporary
// directory and with production runtime overrides removed. Individual tests
// may narrow it further with t.Setenv.
func Main(m *testing.M) {
	homeDir, err := os.MkdirTemp("", "baxter-tests-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, name := range []string{"BAXTER_APP_SUPPORT_DIR", "BAXTER_HOME_DIR", "BAXTER_CONFIG_PATH"} {
		if err := os.Unsetenv(name); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	for _, name := range []string{"HOME", "XDG_CONFIG_HOME"} {
		if err := os.Setenv(name, homeDir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	code := m.Run()
	if err := os.RemoveAll(homeDir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		code = 1
	}
	os.Exit(code)
}
