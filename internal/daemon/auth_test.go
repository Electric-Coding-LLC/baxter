package daemon

import (
	"net/http/httptest"
	"testing"

	"baxter/internal/config"
)

func TestParseIPCAuthTokens(t *testing.T) {
	tokens := parseIPCAuthTokens(" current , next-token ,,  ")
	if len(tokens) != 2 {
		t.Fatalf("expected 2 tokens, got %d", len(tokens))
	}
	if tokens[0] != "current" || tokens[1] != "next-token" {
		t.Fatalf("unexpected tokens: %#v", tokens)
	}
}

func TestAuthorizeIPCRequestWithRotatingTokens(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("current-token, next-token")

	cases := []struct {
		name       string
		token      string
		authorized bool
	}{
		{name: "current token", token: "current-token", authorized: true},
		{name: "next token", token: "next-token", authorized: true},
		{name: "unknown token", token: "wrong-token", authorized: false},
		{name: "missing token", token: "", authorized: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/v1/status", nil)
			if tc.token != "" {
				req.Header.Set(ipcTokenHeader, tc.token)
			}
			if got := d.authorizeIPCRequest(req); got != tc.authorized {
				t.Fatalf("authorizeIPCRequest() = %v, want %v", got, tc.authorized)
			}
		})
	}
}

func TestAuthorizeIPCRequestNoConfiguredTokenAllowsRequest(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest("GET", "/v1/status", nil)
	if !d.authorizeIPCRequest(req) {
		t.Fatal("expected request to be authorized when no IPC token is configured")
	}
}
