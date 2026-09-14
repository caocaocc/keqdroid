package keqdisdns

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const DNSEnvironment = "KEQDIS_BOOTSTRAP_DNS"
const InterfaceEnvironment = "KEQDIS_BOOTSTRAP_INTERFACE"

type Config struct {
	Servers   []string
	Interface string
	index     int
	next      atomic.Uint32
}

var active *Config

// Initialization precedes both core packages' resolver construction. Mutating
// the existing pointer also covers packages which already retained that pointer.
func init() {
	if runtime.GOOS != "darwin" {
		return
	}
	raw, haveDNS := os.LookupEnv(DNSEnvironment)
	iface, haveInterface := os.LookupEnv(InterfaceEnvironment)
	if !haveDNS && !haveInterface {
		return
	}
	config, err := Parse(raw, iface)
	if err == nil {
		var physical *net.Interface
		physical, err = net.InterfaceByName(config.Interface)
		if err == nil {
			if physical.Flags&net.FlagLoopback != 0 {
				err = errors.New("bootstrap DNS interface must not be loopback")
			} else {
				config.index = physical.Index
			}
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "keqdroid bootstrap DNS:", err)
		os.Exit(78)
	}
	active = config
	net.DefaultResolver.PreferGo = true
	net.DefaultResolver.StrictErrors = true
	net.DefaultResolver.Dial = config.dialResolver
}

// Parse accepts only a complete physical-network snapshot. Falling back to the
// host resolver after TUN changes DNS would recursively query the same tunnel.
func Parse(raw, iface string) (*Config, error) {
	if iface == "" || len(iface) > 15 || strings.HasPrefix(iface, "utun") || strings.HasPrefix(iface, "tun") || strings.HasPrefix(iface, "tap") || iface == "lo0" {
		return nil, errors.New("missing or nonphysical bootstrap interface")
	}
	for _, ch := range iface {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') {
			return nil, errors.New("invalid bootstrap interface")
		}
	}
	var input []string
	if err := json.Unmarshal([]byte(raw), &input); err != nil || len(input) == 0 || len(input) > 16 {
		return nil, errors.New("bootstrap DNS must be a nonempty JSON array of at most 16 IP addresses")
	}
	config := &Config{Interface: iface}
	seen := map[string]bool{}
	for _, value := range input {
		addr, err := netip.ParseAddr(value)
		if err != nil {
			return nil, fmt.Errorf("invalid bootstrap DNS address %q", value)
		}
		addr = addr.Unmap()
		if addr.IsUnspecified() || addr.IsLoopback() || addr.IsMulticast() || addr == netip.MustParseAddr("172.19.0.2") || netip.MustParsePrefix("198.18.0.0/15").Contains(addr) {
			return nil, fmt.Errorf("nonphysical bootstrap DNS address %q", value)
		}
		if addr.Zone() != "" && addr.Zone() != iface {
			return nil, errors.New("bootstrap DNS zone differs from physical interface")
		}
		if addr.Is6() && addr.IsLinkLocalUnicast() {
			addr = addr.WithZone(iface)
		}
		value = addr.String()
		if !seen[value] {
			config.Servers = append(config.Servers, value)
			seen[value] = true
		}
	}
	return config, nil
}

func Enabled() bool { return active != nil }

func Servers() []string {
	if active == nil {
		return nil
	}
	return append([]string(nil), active.Servers...)
}

// Resolver keeps unmodified platforms and Proxy sessions on Go's original
// resolver, while fresh resolver instances in the cores share the TUN override.
func Resolver() *net.Resolver {
	if Enabled() {
		return net.DefaultResolver
	}
	return &net.Resolver{}
}

func (c *Config) dialResolver(ctx context.Context, network, _ string) (net.Conn, error) {
	start := int(c.next.Add(1)-1) % len(c.Servers)
	var last error
	for i := range c.Servers {
		conn, err := c.dialServer(ctx, network, c.Servers[(start+i)%len(c.Servers)])
		if err == nil {
			return conn, nil
		}
		last = err
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, last
}

// DialServer lets mihomo keep its normal DNS message and TCP-retry handling,
// while pinning every system-DNS socket to the pre-TUN physical interface.
func DialServer(ctx context.Context, network, server string) (net.Conn, error) {
	if active == nil {
		return nil, errors.New("bootstrap DNS is not active")
	}
	for _, candidate := range active.Servers {
		if candidate == server {
			return active.dialServer(ctx, network, server)
		}
	}
	return nil, errors.New("DNS server is not in the physical-network snapshot")
}

func (c *Config) dialServer(ctx context.Context, network, server string) (net.Conn, error) {
	if network != "udp" && network != "tcp" && network != "udp4" && network != "udp6" && network != "tcp4" && network != "tcp6" {
		return nil, fmt.Errorf("unsupported bootstrap DNS network %q", network)
	}
	addr, err := netip.ParseAddr(server)
	if err != nil {
		return nil, err
	}
	base := "udp"
	if strings.HasPrefix(network, "tcp") {
		base = "tcp"
	}
	if addr.Is4() {
		network = base + "4"
	} else {
		network = base + "6"
	}
	dialer := net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, socket syscall.RawConn) error {
			return bindPhysicalInterface(socket, addr.Is6(), c.index)
		},
	}
	return dialer.DialContext(ctx, network, net.JoinHostPort(server, "53"))
}
