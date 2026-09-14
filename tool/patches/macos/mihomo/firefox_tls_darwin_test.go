package dns

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	coretls "github.com/metacubex/mihomo/component/tls"
	utls "github.com/metacubex/utls"
)

// Keep this in the existing DNS overlay so the normal Mihomo checkpoint runs
// the TLS regression without changing the shared builder or runtime modules.
func TestKeqdisFirefox148ClientHello(t *testing.T) {
	for _, profile := range []string{"firefox", "chrome", "firefox120"} {
		t.Run(profile, func(t *testing.T) {
			fingerprint, ok := coretls.GetFingerprint(profile)
			if !ok {
				t.Fatal("fingerprint missing")
			}
			left, right := net.Pipe()
			defer left.Close()
			defer right.Close()
			conn := coretls.UClient(left, &utls.Config{ServerName: "example.invalid"}, fingerprint)
			if err := conn.BuildHandshakeState(); err != nil {
				t.Fatal(err)
			}
			hybrid, classical := -1, -1
			var classicalKey []byte
			for index, share := range conn.HandshakeState.Hello.KeyShares {
				switch share.Group {
				case utls.X25519MLKEM768:
					hybrid = index
					if len(share.Data) != 1184+32 {
						t.Fatalf("invalid MLKEM public share length: %d", len(share.Data))
					}
				case utls.X25519:
					classical, classicalKey = index, share.Data
				}
			}
			if profile == "firefox120" {
				if hybrid >= 0 {
					t.Fatal("explicit legacy fingerprint silently changed")
				}
				return
			}
			if hybrid < 0 || classical >= 0 && hybrid > classical {
				t.Fatalf("REALITY needs MLKEM before optional X25519: %d, %d", hybrid, classical)
			}
			if profile == "firefox" {
				if fingerprint.Version != "148" || classical < 0 {
					t.Fatal("default Firefox profile was not upgraded")
				}
				keys := conn.HandshakeState.State13.KeyShareKeys
				if keys == nil || keys.Ecdhe == nil || !bytes.Equal(keys.Ecdhe.PublicKey().Bytes(), classicalKey) {
					t.Fatal("REALITY authentication key does not match the emitted X25519 share")
				}
			}
		})
	}
}

func TestKeqdisFirefox148TLSVerification(t *testing.T) {
	// Mihomo retains go 1.20, so the standard-library fixture otherwise inherits
	// tlsmlkem=0. Enable MLKEM only for this server test; uTLS is independent.
	t.Setenv("GODEBUG", os.Getenv("GODEBUG")+",tlsmlkem=1")
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "keqdis-firefox-local-tls")
	}))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13,
		CurvePreferences: []tls.CurveID{tls.X25519MLKEM768}}
	server.StartTLS()
	defer server.Close()

	for _, scenario := range []string{"trusted", "unknown-authority", "wrong-name"} {
		t.Run(scenario, func(t *testing.T) {
			roots := x509.NewCertPool()
			if scenario != "unknown-authority" {
				roots.AddCert(server.Certificate())
			}
			serverName := "127.0.0.1"
			if scenario == "wrong-name" {
				serverName = "not-the-fixture.invalid"
			}
			raw, err := net.DialTimeout("tcp", server.Listener.Addr().String(), 3*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer raw.Close()
			_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
			fingerprint, ok := coretls.GetFingerprint("firefox")
			if !ok {
				t.Fatal("Firefox fingerprint missing")
			}
			conn := coretls.UClient(raw, &utls.Config{RootCAs: roots, ServerName: serverName}, fingerprint)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			err = conn.HandshakeContext(ctx)
			if scenario != "trusted" {
				var untrusted x509.UnknownAuthorityError
				var wrongName x509.HostnameError
				if scenario == "unknown-authority" && !errors.As(err, &untrusted) ||
					scenario == "wrong-name" && !errors.As(err, &wrongName) {
					t.Fatalf("expected certificate rejection, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			state := conn.ConnectionState()
			if state.Version != utls.VersionTLS13 || len(state.VerifiedChains) == 0 ||
				state.NegotiatedProtocol != "http/1.1" ||
				conn.HandshakeState.ServerHello.ServerShare.Group != utls.X25519MLKEM768 {
				t.Fatalf("trusted Firefox TLS negotiation: version=%x chains=%d ALPN=%q share=%x", state.Version, len(state.VerifiedChains), state.NegotiatedProtocol, uint16(conn.HandshakeState.ServerHello.ServerShare.Group))
			}
			if _, err = io.WriteString(conn, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"); err != nil {
				t.Fatal(err)
			}
			response, err := http.ReadResponse(bufio.NewReader(conn), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, err := io.ReadAll(response.Body)
			if err != nil || response.StatusCode != http.StatusOK || string(body) != "keqdis-firefox-local-tls" {
				t.Fatalf("TLS application response: %s, %q, %v", response.Status, body, err)
			}
		})
	}
}
