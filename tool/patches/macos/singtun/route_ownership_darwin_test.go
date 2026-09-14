package tun

import (
	"errors"
	"net/netip"
	"os"
	"syscall"
	"testing"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

func keqdisTestRoute() keqdisOwnedRoute {
	return keqdisOwnedRoute{destination: netip.MustParsePrefix("128.0.0.0/1"),
		gateway: netip.MustParseAddr("172.19.0.1"), interfaceIndex: 42}
}

func keqdisTestMessage(owned keqdisOwnedRoute) *route.RouteMessage {
	message := keqdisRouteMessage(owned.interfaceScope, owned.interfaceIndex,
		owned.destination, owned.gateway)
	message.Index = owned.interfaceIndex
	return message
}

func TestKeqdisRouteOwnershipRequiresExactNetworkGatewayAndInterface(t *testing.T) {
	wanted := keqdisTestRoute()
	for _, tc := range []struct {
		name string
		edit func(*route.RouteMessage)
	}{
		{"other interface", func(m *route.RouteMessage) { m.Index++ }},
		{"other gateway", func(m *route.RouteMessage) {
			m.Addrs[syscall.RTAX_GATEWAY] = &route.Inet4Addr{IP: [4]byte{172, 19, 0, 2}}
		}},
		{"default fallback", func(m *route.RouteMessage) {
			m.Addrs[syscall.RTAX_DST] = &route.Inet4Addr{}
			m.Addrs[syscall.RTAX_NETMASK] = &route.Inet4Addr{}
		}},
		{"different mask", func(m *route.RouteMessage) { m.Addrs[syscall.RTAX_NETMASK] = &route.Inet4Addr{IP: [4]byte{192}} }},
		{"scoped foreign route", func(m *route.RouteMessage) { m.Flags |= unix.RTF_IFSCOPE }},
		{"down", func(m *route.RouteMessage) { m.Flags &^= unix.RTF_UP }},
		{"reject", func(m *route.RouteMessage) { m.Flags |= unix.RTF_REJECT }},
		{"truncated", func(m *route.RouteMessage) { m.Addrs = nil }},
		{"link gateway", func(m *route.RouteMessage) { m.Addrs[syscall.RTAX_GATEWAY] = &route.LinkAddr{Index: 42} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			message := keqdisTestMessage(wanted)
			tc.edit(message)
			if wanted.matches(message) {
				t.Fatal("foreign or malformed route passed ownership check")
			}
		})
	}
	if !wanted.matches(keqdisTestMessage(wanted)) {
		t.Fatal("owned route was rejected")
	}
}

func TestKeqdisRouteOwnershipIPv6AndScopedRoute(t *testing.T) {
	wanted := keqdisOwnedRoute{destination: netip.MustParsePrefix("8000::/1"),
		gateway: netip.MustParseAddr("fdfe:dcba:9876::1"), interfaceIndex: 8, interfaceScope: true}
	if !wanted.matches(keqdisTestMessage(wanted)) {
		t.Fatal("owned IPv6 route rejected")
	}
	changed := keqdisTestMessage(wanted)
	changed.Addrs[syscall.RTAX_GATEWAY] = &route.Inet6Addr{IP: netip.MustParseAddr("fdfe:dcba:9876::2").As16()}
	if wanted.matches(changed) {
		t.Fatal("other IPv6 gateway accepted")
	}
}

func TestKeqdisRouteExistingRouteIsNeverDeletedOrAdopted(t *testing.T) {
	calls := 0
	err := keqdisAddRoute(keqdisTestRoute(), func(candidate keqdisOwnedRoute) error {
		calls++
		return unix.EEXIST
	}, func() ([]route.Message, error) { t.Fatal("queried failed addition"); return nil, nil })
	if !errors.Is(err, unix.EEXIST) || calls != 1 {
		t.Fatalf("unexpected conflict handling: %v %d", err, calls)
	}
}

func TestKeqdisRouteAdditionRequiresKernelInterfaceVerification(t *testing.T) {
	wanted := keqdisTestRoute()
	for _, correct := range []bool{false, true} {
		message := keqdisTestMessage(wanted)
		if !correct {
			message.Index++
		}
		err := keqdisAddRoute(wanted, func(keqdisOwnedRoute) error { return nil }, func() ([]route.Message, error) {
			return []route.Message{message}, nil
		})
		if (err == nil) != correct {
			t.Fatalf("wrong binding accepted: %v", err)
		}
	}
	failure := errors.New("cannot read routing table")
	if err := keqdisAddRoute(wanted, func(keqdisOwnedRoute) error { return nil }, func() ([]route.Message, error) {
		return nil, failure
	}); !errors.Is(err, failure) {
		t.Fatalf("lost verification error: %v", err)
	}
}

func TestKeqdisRoutePartialFailureClosesOwnInterfaceWithoutDeletingRoutes(t *testing.T) {
	wanted := keqdisTestRoute()
	foreign := wanted
	foreign.interfaceIndex++
	table := []route.Message{keqdisTestMessage(foreign)}
	closeCount, addCount := 0, 0
	err := keqdisStartRouteSession(func() error {
		if err := keqdisAddRoute(wanted, func(keqdisOwnedRoute) error {
			addCount++
			table = append(table, keqdisTestMessage(wanted))
			return nil
		}, func() ([]route.Message, error) { return table, nil }); err != nil {
			return err
		}
		return unix.EEXIST
	}, func() error {
		closeCount++
		return nil
	})
	if !errors.Is(err, unix.EEXIST) || closeCount != 1 || addCount != 1 || len(table) != 2 {
		t.Fatalf("cleanup mutated routing table: %v %d %d %v", err, closeCount, addCount, table)
	}
}

func TestKeqdisRouteSuccessfulSessionKeepsInterfaceOpen(t *testing.T) {
	if err := keqdisStartRouteSession(func() error { return nil }, func() error {
		t.Fatal("closed a successful session")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestKeqdisRouteCloseIsIdempotentAndPreventsRestart(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	// A pipe exercises descriptor lifetime without creating any network interface.
	tun := &NativeTun{tunFile: reader, options: Options{EXP_ExternalConfiguration: true}}
	if err := tun.Close(); err != nil {
		t.Fatal(err)
	}
	if err := tun.Close(); err != nil {
		t.Fatalf("second cleanup is not idempotent: %v", err)
	}
	if _, err := reader.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("own descriptor still open: %v", err)
	}
	if _, err := writer.Stat(); err != nil {
		t.Fatalf("unrelated descriptor was closed: %v", err)
	}
	if err := tun.setRoutes(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("closed session restarted: %v", err)
	}
}

func TestKeqdisRouteStartupReportsCloseFailure(t *testing.T) {
	failedStart, failedClose := errors.New("start failed"), errors.New("close failed")
	err := keqdisStartRouteSession(func() error { return failedStart }, func() error { return failedClose })
	if !errors.Is(err, failedStart) || !errors.Is(err, failedClose) {
		t.Fatalf("lost failure: %v", err)
	}
}

func TestKeqdisRouteUpdatesRequireSessionRebuildWithoutChangingOptions(t *testing.T) {
	tun := &NativeTun{options: Options{Name: "utun42"}}
	if err := tun.UpdateRouteOptions(Options{Name: "utun43"}); !errors.Is(err, errKeqdisRouteSessionRebuild) {
		t.Fatalf("expected session rebuild: %v", err)
	}
	if tun.options.Name != "utun42" {
		t.Fatal("changed active route configuration")
	}
}

func TestKeqdisRouteExchangeRefusesEveryNonAddOperation(t *testing.T) {
	for _, operation := range []int{unix.RTM_DELETE, unix.RTM_CHANGE, unix.RTM_GET} {
		message := keqdisTestMessage(keqdisTestRoute())
		message.Type = operation
		if err := keqdisRouteExchange(-1, message); !errors.Is(err, errKeqdisRouteOperation) {
			t.Fatalf("operation %d reached socket IO: %v", operation, err)
		}
	}
}

func TestKeqdisRouteReplyFiltersOtherProcessesAndSequences(t *testing.T) {
	request := keqdisTestMessage(keqdisTestRoute())
	request.ID, request.Seq = 123, 45
	foreign := *request
	foreign.ID++
	old := *request
	old.Seq--
	if _, found := keqdisRouteReply([]route.Message{&foreign, &old}, request); found {
		t.Fatal("accepted unrelated reply")
	}
	failed := *request
	failed.Err = unix.EEXIST
	if err, found := keqdisRouteReply([]route.Message{&foreign, &failed}, request); !found || !errors.Is(err, unix.EEXIST) {
		t.Fatalf("lost kernel error: %v %v", err, found)
	}
}

func TestKeqdisRouteRequestRoundtripPinsActualInterfaceWithoutChangingScope(t *testing.T) {
	wanted := keqdisTestRoute()
	message := keqdisRouteMessage(false, wanted.interfaceIndex, wanted.destination, wanted.gateway)
	data, err := message.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := route.ParseRIB(route.RIBTypeRoute, data)
	if err != nil || len(parsed) != 1 {
		t.Fatalf("invalid route request: %v %v", parsed, err)
	}
	actual := parsed[0].(*route.RouteMessage)
	ifp, ok := actual.Addrs[syscall.RTAX_IFP].(*route.LinkAddr)
	if !ok || ifp.Index != wanted.interfaceIndex || actual.Flags&unix.RTF_IFSCOPE != 0 {
		t.Fatal("route can use a foreign interface with the same gateway, or became scoped")
	}
}
