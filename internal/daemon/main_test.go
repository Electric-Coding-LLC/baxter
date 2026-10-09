package daemon

import (
	"testing"

	"baxter/internal/testhome"
)

// Even tests that only exercise status or scheduling can persist daemon state.
// Give the entire test process a private home; individual tests may narrow it
// further with t.Setenv. Never inherit production runtime overrides.
func TestMain(m *testing.M) {
	testhome.Main(m)
}
