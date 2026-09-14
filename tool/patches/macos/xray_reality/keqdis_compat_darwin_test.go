//go:build darwin

// Copied into Xray's transport/internet/reality for the pinned Go 1.26 build.
// All endpoints, including REALITY's camouflage target, are loopback fixtures.
package reality_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	gotls "crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	utls "github.com/refraction-networking/utls"
	goreality "github.com/xtls/reality"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	xreality "github.com/xtls/xray-core/transport/internet/reality"
	xtls "github.com/xtls/xray-core/transport/internet/tls"
)

func keqdisTLS13Target(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "loopback-tls13")
	}))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.TLS = &gotls.Config{
		MinVersion:       gotls.VersionTLS13,
		CurvePreferences: []gotls.CurveID{gotls.X25519MLKEM768, gotls.X25519},
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}

func TestKeqdisGo126TLS13MLKEM(t *testing.T) {
	server := keqdisTLS13Target(t)
	client := server.Client() // Trusts this fixture certificate only; no skip-verify.
	client.Timeout = 3 * time.Second
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "loopback-tls13" {
		t.Fatalf("TLS payload: %q, %v", body, err)
	}
	if response.TLS.Version != gotls.VersionTLS13 || response.TLS.CurveID != gotls.X25519MLKEM768 {
		t.Fatalf("unexpected TLS negotiation: version=%x curve=%v", response.TLS.Version, response.TLS.CurveID)
	}
}

func TestKeqdisGo126RealityLoopback(t *testing.T) {
	for _, scenario := range []struct {
		name, fingerprint                        string
		badShortID, futureClientVersion, success bool
	}{
		{name: "chrome-mlkem", fingerprint: "chrome", success: true},
		{name: "firefox-mlkem", fingerprint: "firefox", success: true},
		{name: "old-profile-without-mlkem", fingerprint: "hellofirefox_120"},
		{name: "wrong-short-id", fingerprint: "chrome", badShortID: true},
		{name: "minimum-client-version", fingerprint: "chrome", futureClientVersion: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			target := keqdisTLS13Target(t)
			key, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			targetJSON, _ := json.Marshal(target.Listener.Addr().String())
			serverInput := conf.REALITYConfig{
				Target: targetJSON, ServerNames: []string{"example.com"},
				PrivateKey:   base64.RawURLEncoding.EncodeToString(key.Bytes()),
				ShortIds:     []string{"0123456789abcdef"},
				MinClientVer: fmt.Sprintf("%d.%d.%d", core.Version_x, core.Version_y, core.Version_z),
			}
			if scenario.futureClientVersion {
				serverInput.MinClientVer = "255.255.255"
			}
			serverMessage, err := serverInput.Build()
			if err != nil {
				t.Fatal(err)
			}
			serverConfig := serverMessage.(*xreality.Config).GetREALITYConfig()
			// A test regression must never turn this fixture into an external dial.
			serverConfig.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				if network != "tcp" || address != target.Listener.Addr().String() {
					return nil, fmt.Errorf("non-fixture target rejected")
				}
				conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, address)
				if err == nil {
					_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				}
				return conn, err
			}
			// Match Xray's TCP listener startup. Server requires these target
			// records before it releases an authenticated application stream.
			goreality.DetectPostHandshakeRecordsLens(serverConfig)
			deadline := time.Now().Add(3 * time.Second)
			for alpn := range 3 {
				key := fmt.Sprintf("%s example.com %d", serverConfig.Dest, alpn)
				for {
					value, _ := goreality.GlobalPostHandshakeRecordsLens.Load(key)
					if _, ready := value.([]int); ready {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("loopback target records were not ready")
					}
					time.Sleep(time.Millisecond)
				}
				t.Cleanup(func() {
					goreality.GlobalPostHandshakeRecordsLens.Delete(key)
					goreality.GlobalMaxCSSMsgCount.Delete(key)
				})
			}
			clientInput := conf.REALITYConfig{
				Fingerprint: scenario.fingerprint, ServerName: "example.com",
				PublicKey: base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
				ShortId:   "0123456789abcdef", SpiderX: "/",
			}
			if scenario.badShortID {
				clientInput.ShortId = "fedcba9876543210"
			}
			clientMessage, err := clientInput.Build()
			if err != nil {
				t.Fatal(err)
			}
			clientConfig := clientMessage.(*xreality.Config)

			// Inspect the actual pinned uTLS ClientHello, not only a config boolean.
			left, right := net.Pipe()
			hello := utls.UClient(left, &utls.Config{ServerName: "example.com"}, *xtls.GetFingerprint(scenario.fingerprint))
			err = hello.BuildHandshakeState()
			_ = left.Close()
			_ = right.Close()
			if err != nil {
				t.Fatal(err)
			}
			mlkem := false
			for _, share := range hello.HandshakeState.Hello.KeyShares {
				if share.Group == utls.X25519MLKEM768 && len(share.Data) == 1184+32 {
					mlkem = true
				}
			}
			if mlkem != (scenario.fingerprint != "hellofirefox_120") {
				t.Fatalf("unexpected MLKEM key share for %s: %v", scenario.fingerprint, mlkem)
			}

			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			payload := []byte("keqdis-reality-loopback-payload")
			type serverResult struct {
				err     error
				version [3]byte
			}
			done := make(chan serverResult, 1)
			go func() {
				raw, err := listener.Accept()
				if err != nil {
					done <- serverResult{err: err}
					return
				}
				defer raw.Close()
				_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
				conn, err := xreality.Server(raw, serverConfig)
				if err != nil {
					done <- serverResult{err: err}
					return
				}
				defer conn.Close()
				version := conn.(*xreality.Conn).ClientVer
				message := make([]byte, len(payload))
				if _, err = io.ReadFull(conn, message); err == nil {
					if !bytes.Equal(message, payload) {
						err = fmt.Errorf("payload mismatch")
					} else {
						_, err = conn.Write(message)
					}
				}
				done <- serverResult{err: err, version: version}
			}()
			raw, err := net.DialTimeout("tcp", listener.Addr().String(), 3*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer raw.Close()
			_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			conn, handshakeErr := xreality.UClient(raw, clientConfig, ctx,
				xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(listener.Addr().(*net.TCPAddr).Port)))
			if scenario.success {
				if handshakeErr != nil {
					t.Fatal(handshakeErr)
				}
				defer conn.Close()
				verified := conn.(*xreality.UConn)
				if !verified.Verified || verified.ConnectionState().Version != utls.VersionTLS13 ||
					verified.HandshakeState.ServerHello.ServerShare.Group != utls.X25519MLKEM768 {
					t.Fatal("REALITY did not authenticate and negotiate TLS 1.3 MLKEM")
				}
				if _, err = conn.Write(payload); err != nil {
					t.Fatal(err)
				}
				message := make([]byte, len(payload))
				if _, err = io.ReadFull(conn, message); err != nil || !bytes.Equal(message, payload) {
					t.Fatalf("REALITY payload round trip: %v", err)
				}
			} else if handshakeErr == nil {
				_ = conn.Close()
				t.Fatal("unauthorized or outdated REALITY handshake succeeded")
			}
			_ = raw.Close()
			select {
			case result := <-done:
				if scenario.success {
					if result.err != nil || result.version != [3]byte{core.Version_x, core.Version_y, core.Version_z} {
						t.Fatalf("server authentication/version: %v, %v", result.err, result.version)
					}
				} else if result.err == nil || !strings.Contains(result.err.Error(), "processed invalid connection") {
					t.Fatalf("expected explicit REALITY rejection: %v", result.err)
				}
			case <-time.After(4 * time.Second):
				t.Fatal("REALITY fixture did not release its connection")
			}
		})
	}
}
