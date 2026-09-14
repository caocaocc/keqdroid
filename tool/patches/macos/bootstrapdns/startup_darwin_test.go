//go:build darwin

package keqdisdns

import (
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// A subprocess exercises package initialization, before either core constructs
// its own resolver. It never opens a socket or issues a DNS query.
func TestDarwinStartup(t *testing.T) {
	if os.Getenv("KEQDIS_BOOTSTRAP_TEST_CHILD") == "active" {
		if !Enabled() || Resolver() != net.DefaultResolver || net.DefaultResolver.Dial == nil || !net.DefaultResolver.PreferGo {
			t.Fatal("startup did not install the shared physical resolver")
		}
		if _, err := DialServer(t.Context(), "udp", "8.8.8.8"); err == nil {
			t.Fatal("allowed a DNS endpoint outside the snapshot")
		}
		return
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	physical := ""
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback == 0 {
			if _, err := Parse(`["192.0.2.53"]`, iface.Name); err == nil {
				physical = iface.Name
				break
			}
		}
	}
	if physical == "" {
		t.Fatal("Darwin test host has no physical interface")
	}
	for _, tc := range []struct {
		name, dns, iface string
		wantCode         int
	}{
		{"complete", `["192.0.2.53"]`, physical, 0},
		{"empty-dns", `[]`, physical, 78},
		{"missing-interface", `["192.0.2.53"]`, "", 78},
		{"loopback", `["127.0.0.1"]`, physical, 78},
		{"unknown-interface", `["192.0.2.53"]`, "keqmissing0", 78},
	} {
		t.Run(tc.name, func(t *testing.T) {
			command := exec.Command(os.Args[0], "-test.run=^TestDarwinStartup$")
			for _, item := range os.Environ() {
				if !strings.HasPrefix(item, DNSEnvironment+"=") && !strings.HasPrefix(item, InterfaceEnvironment+"=") && !strings.HasPrefix(item, "KEQDIS_BOOTSTRAP_TEST_CHILD=") {
					command.Env = append(command.Env, item)
				}
			}
			command.Env = append(command.Env, "KEQDIS_BOOTSTRAP_TEST_CHILD=active", DNSEnvironment+"="+tc.dns, InterfaceEnvironment+"="+tc.iface)
			output, err := command.CombinedOutput()
			code := 0
			if err != nil {
				if exited, ok := err.(*exec.ExitError); ok {
					code = exited.ExitCode()
				} else {
					t.Fatal(err)
				}
			}
			if code != tc.wantCode {
				t.Fatalf("exit %d, want %d: %s", code, tc.wantCode, output)
			}
		})
	}
}
