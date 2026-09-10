package localdns

import (
	"os"
	"runtime"
	"testing"

	"github.com/xtls/xray-core/common/net"
)

func TestKeqdisFreshResolverUsesBootstrap(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin bootstrap integration")
	}
	t.Setenv("KEQDIS_BOOTSTRAP_DNS", `["192.168.1.1"]`)
	if New().r != net.DefaultResolver {
		t.Fatal("controller resolver bypassed Darwin bootstrap")
	}
}

func TestKeqdisProxyKeepsControllerResolver(t *testing.T) {
	value, exists := os.LookupEnv("KEQDIS_BOOTSTRAP_DNS")
	_ = os.Unsetenv("KEQDIS_BOOTSTRAP_DNS")
	t.Cleanup(func() {
		if exists {
			_ = os.Setenv("KEQDIS_BOOTSTRAP_DNS", value)
		}
	})
	if New().r == net.DefaultResolver {
		t.Fatal("proxy session lost its controller resolver")
	}
}
