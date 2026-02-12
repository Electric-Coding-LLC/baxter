package daemon

import "testing"

func TestValidateIPCAddressDefaultLoopback(t *testing.T) {
	got, err := ValidateIPCAddress("", false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != DefaultIPCAddress {
		t.Fatalf("unexpected default ipc addr: got %q want %q", got, DefaultIPCAddress)
	}
}

func TestValidateIPCAddressAllowsLoopback(t *testing.T) {
	tests := []string{
		"127.0.0.1:41820",
		"127.10.20.30:9000",
		"localhost:8080",
		"[::1]:9999",
	}
	for _, addr := range tests {
		t.Run(addr, func(t *testing.T) {
			if _, err := ValidateIPCAddress(addr, false); err != nil {
				t.Fatalf("expected %q to be allowed: %v", addr, err)
			}
		})
	}
}

func TestValidateIPCAddressRejectsRemoteWithoutOptIn(t *testing.T) {
	tests := []string{
		"0.0.0.0:41820",
		"192.168.1.10:41820",
		"[2001:db8::1]:41820",
		"example.com:41820",
	}
	for _, addr := range tests {
		t.Run(addr, func(t *testing.T) {
			if _, err := ValidateIPCAddress(addr, false); err == nil {
				t.Fatalf("expected %q to be rejected", addr)
			}
		})
	}
}

func TestValidateIPCAddressAllowsRemoteWithOptIn(t *testing.T) {
	tests := []string{
		"0.0.0.0:41820",
		"192.168.1.10:41820",
		"[2001:db8::1]:41820",
		"example.com:41820",
	}
	for _, addr := range tests {
		t.Run(addr, func(t *testing.T) {
			if _, err := ValidateIPCAddress(addr, true); err != nil {
				t.Fatalf("expected %q to be allowed with opt-in: %v", addr, err)
			}
		})
	}
}
