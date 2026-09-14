package dns

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"reflect"
	"testing"
	"time"

	D "github.com/miekg/dns"
)

type testDNSConn struct{ response *bytes.Reader }

func (c *testDNSConn) Read(p []byte) (int, error)       { return c.response.Read(p) }
func (c *testDNSConn) Write(p []byte) (int, error)      { return len(p), nil }
func (c *testDNSConn) Close() error                     { return nil }
func (c *testDNSConn) LocalAddr() net.Addr              { return &net.UDPAddr{} }
func (c *testDNSConn) RemoteAddr() net.Addr             { return &net.UDPAddr{} }
func (c *testDNSConn) SetDeadline(time.Time) error      { return nil }
func (c *testDNSConn) SetReadDeadline(time.Time) error  { return nil }
func (c *testDNSConn) SetWriteDeadline(time.Time) error { return nil }

type testDNSPacketConn struct{ *testDNSConn }

func (c *testDNSPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, e := c.Read(p)
	return n, c.RemoteAddr(), e
}
func (c *testDNSPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) { return c.Write(p) }

func TestKeqdisBootstrapRetriesTruncatedUDPOverTCP(t *testing.T) {
	query := new(D.Msg).SetQuestion("bootstrap.test.", D.TypeA)
	original := dialBootstrap
	t.Cleanup(func() { dialBootstrap = original })
	var networks []string
	dialBootstrap = func(_ context.Context, network, server string) (net.Conn, error) {
		if server != "192.168.7.1" {
			t.Fatalf("unexpected DNS fallback %s", server)
		}
		networks = append(networks, network)
		answer := new(D.Msg).SetReply(query)
		answer.Truncated = network == "udp"
		payload, err := answer.Pack()
		if err != nil {
			return nil, err
		}
		if network == "tcp" {
			framed := make([]byte, 2, len(payload)+2)
			binary.BigEndian.PutUint16(framed, uint16(len(payload)))
			payload = append(framed, payload...)
			return &testDNSConn{bytes.NewReader(payload)}, nil
		}
		return &testDNSPacketConn{&testDNSConn{bytes.NewReader(payload)}}, nil
	}
	answer, err := (&bootstrapClient{server: "192.168.7.1"}).ExchangeContext(context.Background(), query)
	if err != nil {
		t.Fatal(err)
	}
	if answer.Truncated || !reflect.DeepEqual(networks, []string{"udp", "tcp"}) {
		t.Fatalf("TCP fallback failed: truncated=%v, networks=%v", answer.Truncated, networks)
	}
}

func TestKeqdisBootstrapDoesNotUsePublicFallbackOnFailure(t *testing.T) {
	original := dialBootstrap
	t.Cleanup(func() { dialBootstrap = original })
	want := errors.New("physical interface disappeared")
	count := 0
	dialBootstrap = func(context.Context, string, string) (net.Conn, error) { count++; return nil, want }
	_, err := (&bootstrapClient{server: "192.168.7.1"}).ExchangeContext(context.Background(), new(D.Msg).SetQuestion("bootstrap.test.", D.TypeA))
	if !errors.Is(err, want) || count != 1 {
		t.Fatalf("error=%v, attempts=%d", err, count)
	}
}
