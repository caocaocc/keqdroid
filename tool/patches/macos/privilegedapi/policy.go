package keqdisapi

import (
	"net/url"
	"os"
	"runtime"
	"strings"
)

const Environment = "KEQDIS_PRIVILEGED_RUNTIME"

func Enabled() bool {
	return runtime.GOOS == "darwin" && os.Getenv(Environment) == "1"
}

// Allowed is an allowlist because new upstream routes must not silently gain
// root capabilities. Paths are escaped, matching chi's routing representation;
// an escaped slash in a selector name remains part of that name, not a route.
func Allowed(method, escapedPath string) bool {
	if escapedPath == "/" {
		return method == "GET"
	}
	path := strings.TrimSuffix(escapedPath, "/")
	parts := strings.Split(path, "/")
	if len(parts) < 2 || parts[0] != "" {
		return false
	}
	for _, part := range parts[1:] {
		decoded, err := url.PathUnescape(part)
		if err != nil || decoded == "" || decoded == "." || decoded == ".." || strings.ContainsAny(decoded, "\\\x00\r\n") {
			return false
		}
	}
	if method == "GET" {
		switch path {
		case "/version", "/connections", "/traffic", "/memory", "/logs", "/configs", "/proxies", "/rules", "/group":
			return true
		}
		return len(parts) == 3 && (parts[1] == "proxies" || parts[1] == "group")
	}
	if method == "DELETE" {
		return path == "/connections" || len(parts) == 3 && parts[1] == "connections"
	}
	// Both pinned cores validate membership in an already configured selector;
	// this handler cannot construct an outbound, load a file, or replace config.
	return method == "PUT" && len(parts) == 3 && parts[1] == "proxies"
}
