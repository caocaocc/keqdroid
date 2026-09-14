package route

import (
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"runtime"
	"strings"
	"testing"
)

func TestKeqdisPrivilegedCapabilitiesBlocked(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin-only privilege policy")
	}
	t.Setenv("KEQDIS_PRIVILEGED_RUNTIME", "1")
	for _, item := range []struct{ method, path string }{
		{"PUT", "/configs"}, {"PATCH", "/configs"}, {"POST", "/configs/geo"},
		{"POST", "/restart"}, {"POST", "/upgrade"}, {"POST", "/upgrade/ui"},
		{"PUT", "/providers/proxies/name"}, {"PUT", "/providers/rules/name"},
		{"GET", "/providers/proxies/name/healthcheck"}, {"GET", "/ui/root-file"},
		{"GET", "/debug/pprof"}, {"POST", "/dns-query"}, {"PATCH", "/rules/disable"},
		{"PUT", "/storage/file"}, {"POST", "/cache/dns/flush"},
	} {
		called := false
		handler := privilegedRuntimeAPI(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
		request := httptest.NewRequest(item.method, item.path, strings.NewReader("untrusted input"))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if called || response.Code != http.StatusForbidden {
			t.Fatalf("dangerous handler reached: %s %s", item.method, item.path)
		}
	}
}

func TestKeqdisPrivilegePolicyKeepsSessionControls(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin-only privilege policy")
	}
	t.Setenv("KEQDIS_PRIVILEGED_RUNTIME", "1")
	for _, item := range []struct{ method, path string }{
		{"GET", "/connections"}, {"GET", "/version"}, {"DELETE", "/connections"},
		{"DELETE", "/connections/existing-id"}, {"PUT", "/proxies/selector%2Fname"},
	} {
		called := false
		handler := privilegedRuntimeAPI(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(item.method, item.path, nil))
		if !called {
			t.Fatalf("session operation blocked: %s %s", item.method, item.path)
		}
	}
	t.Setenv("KEQDIS_PRIVILEGED_RUNTIME", "")
	called := false
	privilegedRuntimeAPI(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true })).ServeHTTP(
		httptest.NewRecorder(), httptest.NewRequest("PUT", "/configs", nil))
	if !called {
		t.Fatal("ordinary Proxy session changed")
	}
}

func TestKeqdisRootRouterAppliesGuardAndAuthentication(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin-only privilege policy")
	}
	t.Setenv("KEQDIS_PRIVILEGED_RUNTIME", "1")
	handler := keqdisTestRouter(t)
	// Unknown routes cannot invoke a real privileged handler if this assertion
	// fails; all capability tests above use a sentinel, never network operations.
	for _, path := range []string{"/future-root-api", "/ui/fixture"} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != http.StatusForbidden {
			t.Fatalf("global router guard missing: %s returned %d", path, response.Code)
		}
	}
	for _, authorized := range []bool{false, true} {
		request := httptest.NewRequest("GET", "/version", nil)
		if authorized {
			request.Header.Set("Authorization", "Bearer test-secret")
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		expected := http.StatusUnauthorized
		if authorized {
			expected = http.StatusOK
		}
		if response.Code != expected {
			t.Fatalf("read authentication changed: got %d, want %d", response.Code, expected)
		}
	}
}

func keqdisTestRouter(t *testing.T) http.Handler {
	t.Helper()
	return router(true, "test-secret", "/dns-query", Cors{})
}
