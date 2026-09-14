package route

import (
	"strings"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/internal/keqdisapi"
)

func privilegedRuntimeAPI(next http.Handler) http.Handler {
	if !keqdisapi.Enabled() {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !privilegedMihomoOperation(r.Method, r.URL.EscapedPath()) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"This operation requires a new helper-validated session"}`))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// The pinned Mihomo handlers only serialize existing provider state and clear
// an automatic group's fixed member. Provider reload and health checks remain
// denied. Keep these Mihomo-specific routes out of the sing-box allowlist.
func privilegedMihomoOperation(method, path string) bool {
	if keqdisapi.Allowed(method, path) {
		return true
	}
	if method == "GET" && strings.TrimSuffix(path, "/") == "/providers/proxies" {
		return true
	}
	// Reuse the exact escaped single-selector path validation for PUT. DELETE
	// reaches unfixedProxy, which cannot add a group or select a new outbound.
	return method == "DELETE" && keqdisapi.Allowed("PUT", path)
}
