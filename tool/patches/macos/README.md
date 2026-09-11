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
  With the protected Darwin context it also pins Xray's actual TCP/UDP system
  sockets to the captured interface, after applying controller/socket options.
  Interface name/index changes, option failures and failed binding/readback
  abort the connection. This prevents embedded Xray traffic from re-entering
  the TUN before process routing can identify it. Exact loopback destinations
  remain local; an exempt UDP socket rejects subsequent non-loopback writes.
  Chain redirection still occurs before the physical socket is created. No
  context and non-Darwin builds keep upstream behavior. This covers the default
  Xray system dialer, not arbitrary replacement dialers or wireproxy's sockets.
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

## DoH connection lifetime

`singbox-doh-connection-lifetime.patch` keeps a Darwin HTTP/2 DNS connection
alive independently of the request that first opened it. The embedded Xray
dispatcher retains its dial context for the whole stream; cancelling a finished
DNS query previously closed the shared HTTP/2 connection and interrupted other
queries with `unexpected EOF`. Cancellation still reaches the TCP/TLS dial until
the TLS handshake completes. Afterwards, the connection and the DNS transport
own cancellation. Transport shutdown closes pending and active managed HTTP/2
connections, including those retained across a reset. HTTP/1.1 keeps its existing
dialer and cancellation behavior, including TLS metadata and protocol fallback.
Non-Darwin builds keep the original context behavior. DNS upstreams, routes,
query timeouts and the helper's readiness deadlines do not change.

`keqrnel-doh-lifetime-tests.patch` adds DNS-over-proxy integration regressions to
the already executed `core/localdns` test package. They use synthetic loopback
HTTP/2 and proxy servers rather than public resolvers or user credentials. The
tests validate connection sharing and cancellation, not real TUN routing or
system DNS readiness; those remain separate device acceptance checks.

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

## Darwin route ownership

`singtun-route-ownership.patch` pins the existing keqrnel dependency
`github.com/sagernet/sing-tun` at `v0.8.12-0.20260810140523-7c73233bd0fb`;
it does not upgrade the upstream version. The replacement also applies to
the sing-box test module. Mihomo's separately pinned sing-tun implementation
does not explicitly delete routes and does not use this replacement.

An `EEXIST` response stops startup without changing the existing route.
Every addition names the actual utun interface through `RTA_IFP`, waits for
its matching process/sequence acknowledgement, then rereads the kernel table
to verify the exact prefix, gateway, interface index and scope. A failed
verification aborts startup and closes the session's own interface descriptor.

Closing the descriptor lets the Darwin kernel detach that utun and remove
routes still bound to that interface. The patch never sends `RTM_DELETE` or
`RTM_CHANGE`; the routing socket entry point rejects every operation except
`RTM_ADD` before touching the socket. This avoids comparing a route and then
deleting a different route installed by another VPN between the two calls.
Cleanup is idempotent, including a partial startup failure followed by the
normal core shutdown path. Dynamic route updates return an explicit error
requiring a new session; the helper must rebuild the session instead.

The ownership check is for readiness, not permission to delete a prefix.
The kernel teardown checks the actual route's `rt_ifp` while holding its
routing lock, including static gateway routes; routes now bound to another
interface are preserved. Relevant Apple sources are
[`utun_ctl_disconnect`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c),
[`if_rtproto_del` and `if_rtdel`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if.c),
and [`RTA_IFP` handling](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c).
The same path exists in macOS 12's `xnu-8019.80.24`:
[`if_proto_free`](https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.80.24/bsd/net/dlil.c#L1672)
calls the same [interface-specific route cleanup](https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.80.24/bsd/net/if.c#L5293).
Detach can complete asynchronously after the descriptor closes. The helper
must wait for the session interface and its routes to disappear, and report
incomplete recovery on timeout; it must not attempt prefix-based deletion.

Tests use simulated route tables, serialized messages and an ordinary pipe
for descriptor lifetime; they never create a TUN or change real routes.
Live TUN and routing recovery validation must be performed with user
authorization on the target macOS versions and architectures.
