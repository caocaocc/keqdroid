# Darwin core overlays

`tool/build_macos_cores.sh` downloads and verifies the exact Go toolchain and
source archives in `tool/macos/core-manifest.json`, reapplies the existing
Mihomo patches, installs these overlays, runs the Darwin tests, and builds both
architectures. `--arch arm64` or `--arch x64` selects one architecture.
The build never runs a proxy, opens a TUN device, or changes network settings.
Caches live in `/tmp/keqdroid-tools`; extracted sources, logs, and outputs live
under `build/macos-cores`. No system Go installation is required.

Each architecture contains `keqrnel`, `mihomo`, `wireproxy`, and
`provenance.json`. The provenance records source, patch, and binary SHA-256
digests. Packaging must hash binaries again after signing because signing
changes their bytes. The build rejects a non-Darwin executable, a mismatched
architecture, or a Mach-O minimum deployment version above macOS 12.

## Bootstrap contract

The helper captures the physical network **before** starting TUN or changing
system DNS. It passes both environment variables to each managed core and any
temporary measurement core that runs while TUN is active:

* `KEQDIS_BOOTSTRAP_DNS`: JSON array of physical DNS server IP strings.
* `KEQDIS_BOOTSTRAP_INTERFACE`: physical BSD interface name, such as `en0`.

On Darwin, a complete snapshot replaces implicit system DNS only. UDP and TCP
queries use the captured IPs and `IP_BOUND_IF` / `IPV6_BOUND_IF` socket options.
The server address is always an IP literal, so connecting cannot recursively
invoke the system resolver. IPv6 link-local servers are scoped to that
interface. Explicit configured DNS servers retain their configured semantics.

Absent both variables, Proxy sessions and other platforms retain upstream
behavior. A partial or invalid snapshot exits with code 78. Socket binding and
lookup failures propagate; there is no public resolver fallback. If the
physical network changes, the helper must stop and restore the session and
capture a new snapshot rather than reuse the previous interface or DNS list.

The parser rejects loopback, unspecified and multicast addresses, virtual
`172.19.0.2`, and the default fake-IP pool `198.18.0.0/15`. The helper must also
reject the actual custom fake-IP range and virtual DNS address computed from
the final session configuration. Empty or recursive snapshots are errors, not
permission to substitute public DNS.

## Coverage

* `keqrnel-bootstrap-dns.patch` redirects `core/localdns`'s freshly constructed
  `net.Resolver` to the bootstrap resolver.
* `xray-bootstrap-dns.patch` preserves that same resolver when Xray constructs
  its controller-owned local DNS client. Mutating the original
  `net.DefaultResolver` also covers Xray's retained alias and implicit lookups.
* `mihomo-bootstrap-dns.patch` makes `system` DNS use the captured list through
  bound clients, disables its public fallback for active bootstrap sessions,
  and prevents `main` from replacing the installed resolver with its upstream
  defensive panic handler. The client retries truncated UDP responses over
  TCP without changing the selected server.
* Wireproxy gets a Darwin main-package import of the shared overlay, covering
  its `net.DefaultResolver.LookupHost` endpoint resolution.

Tests validate snapshot rejection, package initialization in subprocesses,
fresh resolver sharing, binding error propagation, and Mihomo UDP-to-TCP retry
and failure behavior. They use simulated DNS messages and do not send DNS
packets. The build executes them on its macOS host and cross-compiles the
other architecture. Real TUN, sleep/wake, DHCP changes, IPv6-only networks, and
both CPU architectures still require device acceptance testing.

## Privileged Clash API

The helper additionally sets `KEQDIS_PRIVILEGED_RUNTIME=1` for its Darwin root
TUN cores. The value comes from the helper, never the GUI request. Ordinary
Proxy processes do not receive it. This policy is independent of DNS bootstrap.

`mihomo-privileged-api.patch` and `singbox-privileged-api.patch` install an
outermost method/path allowlist, including the routes that upstream exposes
outside authentication (UI, debugging and DoH). The pinned sing-box 1.13.19
archive is a verified local replacement in keqrnel's module graph.

Allowed reads are `/`, `/version`, `/connections`, `/traffic`, `/memory`,
`/logs`, `/configs`, `/proxies`, `/rules`, `/group`, and existing proxy/group
details. The only writes are DELETE `/connections[/id]` and PUT
`/proxies/{selector}`. In both pinned cores, selection only chooses a member
of an already configured group; it cannot load a file or construct an outbound.
Bearer-token authentication remains mandatory for these permitted operations.

All other operations return 403, including configuration replacement/patching,
core/UI/geo upgrades, restarts, provider updates and health checks, debug/UI/DoH,
storage and cache writes. A new configuration must pass through the helper's
session validator. New upstream routes are denied by default. Startup resources
and automatic provider loading still depend on that validator: an HTTP guard
cannot make an unsafe initial configuration safe.

The tests exercise the real router constructor and authentication without
starting a server. Forbidden capability tests use sentinel handlers so a
regression cannot run an updater, open a TUN device, or perform network I/O.
