package keqdisapi

import "testing"

func TestPrivilegedAPIAllowlist(t *testing.T) {
	for _, request := range []struct{ method, path string }{
		{"GET", "/connections"}, {"GET", "/connections/"}, {"GET", "/traffic"}, {"GET", "/version"},
		{"GET", "/proxies"}, {"GET", "/proxies/Hong%20Kong"}, {"GET", "/group/selected"},
		{"DELETE", "/connections"}, {"DELETE", "/connections/unique-id"},
		{"PUT", "/proxies/selected"}, {"PUT", "/proxies/selector%2Fwith%2Fslash"},
	} {
		if !Allowed(request.method, request.path) {
			t.Errorf("rejected supported operation %s %s", request.method, request.path)
		}
	}
	for _, request := range []struct{ method, path string }{
		{"PUT", "/configs"}, {"PATCH", "/configs/"}, {"POST", "/configs/geo"},
		{"POST", "/upgrade"}, {"POST", "/upgrade/ui"}, {"POST", "/restart"},
		{"PUT", "/providers/proxies/name"}, {"PUT", "/providers/rules/name"},
		{"GET", "/providers/proxies/name/healthcheck"}, {"GET", "/proxies/name/delay"},
		{"PATCH", "/rules/disable"}, {"PUT", "/storage/anything"}, {"POST", "/cache/dns/flush"},
		{"GET", "/ui/secret"}, {"GET", "/debug/pprof"}, {"PUT", "/debug/gc"}, {"POST", "/dns-query"},
		{"GET", "/future-root-api"}, {"PUT", "/proxies/a/../../configs"},
		{"PUT", "/proxies/.."}, {"PUT", "/proxies/%2e%2e"}, {"PUT", "/proxies/%00"},
		{"PUT", "/proxies//"}, {"PUT", "//proxies/name"}, {"PUT", "/%70roxies/name"},
		{"DELETE", "/connections/id/extra"}, {"DELETE", "/proxies/name"}, {"OPTIONS", "/configs"},
	} {
		if Allowed(request.method, request.path) {
			t.Errorf("allowed a privileged capability %s %s", request.method, request.path)
		}
	}
}
