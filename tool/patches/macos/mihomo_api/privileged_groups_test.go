package route

import (
	"runtime"
	"strings"
	"testing"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/component/profile"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

// Embedded nil interfaces deliberately fail if these routes attempt any
// operation beyond reading metadata or clearing an already configured group.
type keqdisReadProvider struct {
	P.ProxyProvider
	reads int
}

func (p *keqdisReadProvider) MarshalJSON() ([]byte, error) {
	p.reads++
	return []byte(`{"proxies":[{"name":"member","history":[{"delay":12}]}]}`), nil
}

type keqdisFixedGroup struct {
	C.ProxyAdapter
	fixed  string
	clears int
}

func (g *keqdisFixedGroup) Set(string) error     { panic("unfix selected an arbitrary member") }
func (g *keqdisFixedGroup) ForceSet(name string) { g.fixed = name; g.clears++ }

type keqdisGroupProxy struct {
	C.Proxy
	group *keqdisFixedGroup
	kind  C.AdapterType
}

func (p keqdisGroupProxy) Adapter() C.ProxyAdapter { return p.group }
func (p keqdisGroupProxy) Name() string            { return "auto/group" }
func (p keqdisGroupProxy) Type() C.AdapterType     { return p.kind }

func TestKeqdisGroupsOnlyReadOrUnfixExistingState(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin-only privilege policy")
	}
	t.Setenv("KEQDIS_PRIVILEGED_RUNTIME", "1")
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	t.Cleanup(func() { tunnel.UpdateProxies(oldProxies, oldProviders) })
	oldHome, oldStore := C.Path.HomeDir(), profile.StoreSelected.Load()
	C.SetHomeDir(t.TempDir())
	profile.StoreSelected.Store(true)
	t.Cleanup(func() { C.SetHomeDir(oldHome); profile.StoreSelected.Store(oldStore) })

	provider := &keqdisReadProvider{}
	group := &keqdisFixedGroup{fixed: "member"}
	proxies := map[string]C.Proxy{"auto/group": keqdisGroupProxy{group: group, kind: C.URLTest}}
	tunnel.UpdateProxies(proxies, map[string]P.ProxyProvider{"fixture": provider})
	handler := keqdisTestRouter(t)
	request := func(method, path string, authorized bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if authorized {
			r.Header.Set("Authorization", "Bearer test-secret")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	for _, item := range []struct{ method, path string }{
		{"GET", "/providers/proxies"}, {"DELETE", "/proxies/auto%2Fgroup"},
	} {
		if w := request(item.method, item.path, false); w.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated group request returned %d", w.Code)
		}
	}
	if provider.reads != 0 || group.clears != 0 {
		t.Fatal("unauthenticated request reached state")
	}
	if w := request("GET", "/providers/proxies", true); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"delay":12`) {
		t.Fatalf("provider metadata unavailable: %d %s", w.Code, w.Body.String())
	}
	if provider.reads != 1 {
		t.Fatalf("metadata reads: %d", provider.reads)
	}
	cachefile.Cache().SetSelected("auto/group", "member")
	if w := request("DELETE", "/proxies/auto%2Fgroup", true); w.Code != http.StatusNoContent {
		t.Fatalf("unfix failed: %d %s", w.Code, w.Body.String())
	}
	if group.clears != 1 || group.fixed != "" || cachefile.Cache().SelectedMap()["auto/group"] != "" {
		t.Fatal("unfix did not clear only the existing fixed selection")
	}
	if w := request("DELETE", "/proxies/missing", true); w.Code != http.StatusNotFound {
		t.Fatal("missing group was created")
	}
	proxies["auto/group"] = keqdisGroupProxy{group: group, kind: C.Selector}
	if w := request("DELETE", "/proxies/auto%2Fgroup", true); w.Code != http.StatusBadRequest {
		t.Fatal("plain selector was unfixed")
	}
	if group.clears != 1 {
		t.Fatal("rejected operation changed selection")
	}
	for _, item := range []struct{ method, path string }{
		{"PUT", "/providers/proxies/fixture"}, {"GET", "/providers/proxies/fixture/healthcheck"},
		{"DELETE", "/proxies/auto%2Fgroup/extra"}, {"DELETE", "/configs"},
	} {
		if w := request(item.method, item.path, true); w.Code != http.StatusForbidden {
			t.Fatalf("unapproved route reached state: %s %s (%d)", item.method, item.path, w.Code)
		}
	}
}
