package keqdisdns

import (
	"net"
	"reflect"
	"testing"
)

func TestSnapshotValidation(t *testing.T) {
	cases := []struct{ dns, iface string }{
		{"", "en0"}, {"[]", "en0"}, {"null", "en0"}, {`["192.168.1.1"]`, ""},
		{`["192.168.1.1"]`, "utun8"}, {`["192.168.1.1"]`, "lo0"},
		{`["192.168.1.1"]`, "en0;id"}, {`["resolver.example"]`, "en0"},
		{`["192.168.1.1:53"]`, "en0"}, {`["127.0.0.1"]`, "en0"},
		{`["::1"]`, "en0"}, {`["0.0.0.0"]`, "en0"}, {`["::"]`, "en0"},
		{`["224.0.0.1"]`, "en0"}, {`["172.19.0.2"]`, "en0"},
		{`["198.18.0.2"]`, "en0"}, {`["198.19.1.1"]`, "en0"},
		{`["fe80::1%en1"]`, "en0"}, {`["::ffff:127.0.0.1"]`, "en0"},
		{`["192.168.1.1", "garbage"]`, "en0"},
	}
	for _, tc := range cases {
		if _, err := Parse(tc.dns, tc.iface); err == nil {
			t.Errorf("accepted invalid snapshot %q %q", tc.dns, tc.iface)
		}
	}
}

func TestPreservesPhysicalServersAndScopesIPv6(t *testing.T) {
	config, err := Parse(`["192.168.1.1", "192.168.1.1", "fe80::1", "2001:db8::53"]`, "en0")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"192.168.1.1", "fe80::1%en0", "2001:db8::53"}
	if !reflect.DeepEqual(config.Servers, want) {
		t.Fatalf("got %v, want %v", config.Servers, want)
	}
}

func TestResolverOnlyOverridesActiveSessions(t *testing.T) {
	previous := active
	t.Cleanup(func() { active = previous })
	active = nil
	if Resolver() == net.DefaultResolver {
		t.Fatal("inactive session must retain a fresh system resolver")
	}
	active = &Config{Servers: []string{"192.168.1.1"}, Interface: "en0"}
	if Resolver() != net.DefaultResolver {
		t.Fatal("fresh core resolver escaped the active override")
	}
	servers := Servers()
	servers[0] = "8.8.8.8"
	if active.Servers[0] != "192.168.1.1" {
		t.Fatal("caller mutated the DNS snapshot")
	}
}
