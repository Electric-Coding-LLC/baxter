package daemon

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

const ipcTokenHeader = "X-Baxter-Token"

func (d *Daemon) requireIPCAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !d.authorizeIPCRequest(r) {
			d.writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid IPC token")
			return
		}
		next(w, r)
	}
}

func (d *Daemon) requireIPCWriteAuth(next http.HandlerFunc) http.HandlerFunc {
	return d.requireIPCAuth(next)
}

func (d *Daemon) authorizeIPCRequest(r *http.Request) bool {
	d.mu.Lock()
	tokenConfig := d.ipcAuthToken
	d.mu.Unlock()

	tokens := parseIPCAuthTokens(tokenConfig)
	if len(tokens) == 0 {
		return true
	}

	candidate := strings.TrimSpace(r.Header.Get(ipcTokenHeader))
	if candidate == "" {
		return false
	}

	matched := 0
	for _, token := range tokens {
		matched |= subtle.ConstantTimeCompare([]byte(token), []byte(candidate))
	}
	return matched == 1
}

func (d *Daemon) authorizeIPCWriteRequest(r *http.Request) bool {
	return d.authorizeIPCRequest(r)
}

func parseIPCAuthTokens(raw string) []string {
	parts := strings.Split(raw, ",")
	tokens := make([]string, 0, len(parts))
	for _, part := range parts {
		token := strings.TrimSpace(part)
		if token == "" {
			continue
		}
		tokens = append(tokens, token)
	}
	return tokens
}
