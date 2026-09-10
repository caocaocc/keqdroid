package route

import (
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/internal/keqdisapi"
)

func privilegedRuntimeAPI(next http.Handler) http.Handler {
	if !keqdisapi.Enabled() {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !keqdisapi.Allowed(r.Method, r.URL.EscapedPath()) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"This operation requires a new helper-validated session"}`))
			return
		}
		next.ServeHTTP(w, r)
	})
}
