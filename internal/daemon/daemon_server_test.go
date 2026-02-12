package daemon

import (
	"testing"

	"baxter/internal/config"
)

func TestNewHTTPServerAppliesSecurityLimits(t *testing.T) {
	d := New(config.DefaultConfig())
	srv := d.newHTTPServer()

	if srv.ReadHeaderTimeout != serverReadHeaderTimeout {
		t.Fatalf("read header timeout: got %s want %s", srv.ReadHeaderTimeout, serverReadHeaderTimeout)
	}
	if srv.ReadTimeout != serverReadTimeout {
		t.Fatalf("read timeout: got %s want %s", srv.ReadTimeout, serverReadTimeout)
	}
	if srv.WriteTimeout != serverWriteTimeout {
		t.Fatalf("write timeout: got %s want %s", srv.WriteTimeout, serverWriteTimeout)
	}
	if srv.IdleTimeout != serverIdleTimeout {
		t.Fatalf("idle timeout: got %s want %s", srv.IdleTimeout, serverIdleTimeout)
	}
	if srv.MaxHeaderBytes != serverMaxHeaderBytes {
		t.Fatalf("max header bytes: got %d want %d", srv.MaxHeaderBytes, serverMaxHeaderBytes)
	}
}
