package daemon

import (
	"fmt"
	"os"
	"testing"
)

// Even tests that only exercise status or scheduling can persist daemon state.
// Give the entire test process a private home; individual tests may narrow it
// further with t.Setenv. Never inherit production runtime overrides.
func TestMain(m *testing.M) {
	homeDir, err := os.MkdirTemp("", "baxter-daemon-tests-")
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
