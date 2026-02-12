package daemon

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

const ipcTokenHeader = "X-Baxter-Token"

func (d *Daemon) requireIPCWriteAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !d.authorizeIPCWriteRequest(r) {
			d.writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid IPC token")
			return
		}
		next(w, r)
	}
}

func (d *Daemon) authorizeIPCWriteRequest(r *http.Request) bool {
	d.mu.Lock()
	token := strings.TrimSpace(d.ipcAuthToken)
	d.mu.Unlock()

	if token == "" {
		return true
	}

	candidate := strings.TrimSpace(r.Header.Get(ipcTokenHeader))
	if candidate == "" {
		return false
	}

	return subtle.ConstantTimeCompare([]byte(token), []byte(candidate)) == 1
}
