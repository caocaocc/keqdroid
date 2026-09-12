// CLT-compatible native validation runner. No system settings or privileged
// installation are touched. XCTest coverage is also available with full Xcode.
import Foundation
import NetworkServiceKit
import KEQNetworkClient
import CNetworkXPC
import Darwin
import dnssd

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--validate-request" {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceFailure("invalidRequest", "Request must be an object.") }
        _ = try SessionRequest(arguments: arguments)
        print("{\"valid\":true}")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--dns-diagnostics-only" {
    print("Passed \(runTUNDNSDiagnosticsChecks()) asynchronous TUN DNS diagnostic checks (no network operations).")
    exit(0)
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--mihomo-transport-paths-only" {
    print("Passed \(runMihomoTransportPathChecks()) Mihomo HTTP transport path checks (no network operations).")
    exit(0)
}

var checks = 0
checks += runMihomoTransportPathChecks()
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); fputs("FAIL: accepted \(label)\n", stderr); exit(1) }
    catch { checks += 1 }
}

let changes = ["HTTPEnable": FieldChange(before: 0, applied: 1), "HTTPProxy": FieldChange(before: nil, applied: "127.0.0.1")]
let restored = restoreFields(current: ["HTTPEnable": 1, "HTTPProxy": "other.proxy", "Other": 42], changes: changes)
expect(restored["HTTPEnable"] as? Int == 0, "restore original enable flag")
expect(restored["HTTPProxy"] as? String == "other.proxy", "preserve third-party proxy changes")
expect(restored["Other"] as? Int == 42, "preserve unrelated protocol fields")
expect(restoreProtocolEnabled(current: true, before: false, fields: ["HTTPEnable": 1, "HTTPProxy": "other.proxy"], changes: changes), "third-party fields preserve enabled protocol")
expect(!restoreProtocolEnabled(current: true, before: false, fields: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1"], changes: changes), "owned fields restore previously disabled protocol")
let dns = restoreFields(current: ["ServerAddresses": ["172.19.0.2"], "SearchDomains": ["office.test"]], changes: ["ServerAddresses": FieldChange(before: nil, applied: ["172.19.0.2"])])
expect(dns["ServerAddresses"] == nil, "restore automatic DNS absence")
expect(dns["SearchDomains"] as? [String] == ["office.test"], "preserve DNS search domains")
let roundTrip = FieldChange(dictionary: FieldChange(before: ["1.1.1.1"], applied: ["172.19.0.2"]).dictionary)
expect(roundTrip.before as? [String] == ["1.1.1.1"], "persisted field journal decodes")
for value in ["127.0.0.1", "::1", "172.19.0.2", "198.18.0.2", "fe80::1", "FF02::1", "224.0.0.1", "0.1.2.3", "not-a-host"] { expect(!isPhysicalDNSAddress(value), "reject bootstrap DNS \(value)") }
for value in ["192.168.1.1", "8.8.8.8", "2001:4860:4860::8888"] { expect(isPhysicalDNSAddress(value), "accept physical DNS \(value)") }

let wireproxy = "[Interface]\nPrivateKey = example\nAddress = 10.0.0.1/32\n[Peer]\nPublicKey = example\nEndpoint = example.test:1234\n[Socks5]\nBindAddress = 127.0.0.1:2080\n[http]\nBindAddress = 127.0.0.1:2081"

let secret = "0123456789abcdef"
let valid: [String: Any] = ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]], "inbounds": [["type": "socks", "listen": "127.0.0.1", "listen_port": 2080]], "outbounds": [["type": "direct"]]]
func validate(_ object: [String: Any]) throws { try ConfigPolicy.validateJSON(object, core: "keqrnel", mode: "proxy", ports: [2080, 2081, 9090], apiPort: 9090, secret: secret) }
do { try validate(valid); checks += 1 } catch { fputs("FAIL: valid proxy config \(error)\n", stderr); exit(1) }
func validateDNS(_ dns: Any, tun: Bool = false) throws {
    var object = valid
    object["dns"] = dns
    if tun { object["inbounds"] = [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30"]]] }
    try ConfigPolicy.validateJSON(object, core: "keqrnel", mode: tun ? "tun" : "proxy", ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
}
let dohServer: [String: Any] = ["type": "https", "tag": "proxy-dns", "server": "1.1.1.1", "path": "/dns-query"]
for tun in [false, true] {
    for path in ["/dns-query", "", "/", "/custom/dns%2Dquery", "/" + String(repeating: "a", count: 2047)] {
        var server = dohServer; server["path"] = path
        do { try validateDNS(["servers": [server]], tun: tun); checks += 1 }
        catch { fputs("FAIL: DoH URL path rejected in \(tun ? "TUN" : "Proxy"): \(error)\n", stderr); exit(1) }
    }
}
for path in [NSNull(), false, 123, ["/dns-query"], ["path": "/dns-query"], "dns-query", "file:///etc/sudoers", "/" + String(repeating: "a", count: 2048), "/dns\r\nInjected", "/dns\0", "/dns\u{7f}", "/dns%00", "/dns%0a", "/dns%XX"] as [Any] {
    rejects("malformed DoH URL path") { var server = dohServer; server["path"] = path; try validateDNS(["servers": [server]]) }
}
for kind in ["hosts", "file", "local", "tcp", "HTTPS", ""] {
    rejects("DoH path exemption for non-HTTPS transport") { var server = dohServer; server["type"] = kind; try validateDNS(["servers": [server]]) }
}
let disguisedDNS: [Any] = [
    ["servers": dohServer], ["servers": [[dohServer]]], [["servers": [dohServer]]],
    ["servers": [["type": "https", "nested": ["path": "/etc/sudoers"]]]],
    ["nested": ["dns": ["servers": [dohServer]]]],
    ["servers": [["type": "https", "path": "/dns-query", "tls": ["certificate_path": "/etc/private.pem"]]]],
    ["servers": [["type": "hosts", "path": "/etc/hosts"]]]
]
for object in disguisedDNS { rejects("DoH path exemption outside exact server array item") { try validateDNS(object) } }
rejects("DoH path exemption in outbound") { var object = valid; object["outbounds"] = [["dns": ["servers": [dohServer]]]]; try validate(object) }
rejects("DoH path exemption in Mihomo") {
    try ConfigPolicy.validateJSON(["dns": ["servers": [dohServer]], "external-controller": "127.0.0.1:9090", "secret": secret, "geodata-mode": true, "geo-auto-update": false], core: "mihomo", mode: "proxy", ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
}
for (name, payload) in ["root output path": ["log": ["output": "/etc/sudoers"]], "certificate read": ["tls": ["certificate_path": "/etc/private.pem"]], "nested command": ["outbounds": [["xray": ["command": "/bin/sh"]]]]] as [String: [String: Any]] {
    rejects(name) { var modified = valid; modified.merge(payload) { _, new in new }; try validate(modified) }
}
rejects("unauthenticated API") { var modified = valid; modified["experimental"] = ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": "wrong"]]; try validate(modified) }
rejects("non-loopback listener") { var modified = valid; modified["inbounds"] = [["type": "socks", "listen": "0.0.0.0", "listen_port": 2080]]; try validate(modified) }
rejects("unallocated port") { var modified = valid; modified["inbounds"] = [["type": "socks", "listen": "127.0.0.1", "listen_port": 22]]; try validate(modified) }
rejects("embedded server transport bypass") { var bad = valid; bad["outbounds"] = [["type": "xray", "xray": ["inbounds": [["listen": "127.0.0.1", "port": 2080, "protocol": "socks", "streamSettings": ["network": "hysteria"]]]]]]; try validate(bad) }
rejects("embedded unauthenticated management API") { var bad = valid; bad["outbounds"] = [["type": "xray", "xray": ["api": ["listen": "127.0.0.1:23002", "services": ["HandlerService"]]]]]; try validate(bad) }
rejects("host file-serving inbound") { var bad = valid; bad["inbounds"] = [["type": "hysteria2", "listen": "127.0.0.1", "listen_port": 2080]]; try validate(bad) }
rejects("external file masquerade") { var bad = valid; bad["masquerade"] = "file:///private/var/root"; try validate(bad) }
rejects("external geodata path") { var bad = valid; bad["route"] = ["rules": [["domain": ["ext:/etc/synthetic:tag"]]]]; try validate(bad) }
rejects("outbound TLS master key log") { var bad = valid; bad["outbounds"] = [["type": "xray", "xray": ["outbounds": [["streamSettings": ["tlsSettings": ["masterKeyLog": "/private/var/root/synthetic"]]]]]]]; try validate(bad) }
var httpTransport = valid
httpTransport["outbounds"] = [["type": "xray", "xray": ["outbounds": [["protocol": "vless", "streamSettings": ["wsSettings": ["path": "/transport?test=1"]]]]]]]
do { try validate(httpTransport); checks += 1 } catch { fputs("FAIL: HTTP transport path rejected \(error)\n", stderr); exit(1) }
var cached: [String: Any] = ["external-controller": "127.0.0.1:9090", "secret": secret, "geodata-mode": true, "geo-auto-update": false, "profile": ["store-selected": true], "proxy-providers": ["subscription": ["type": "http", "url": "https://example.test/providers", "path": "providers/subscription.yaml"]]]
func validateMihomo(_ object: [String: Any], mode: String = "proxy") throws { try ConfigPolicy.validateJSON(object, core: "mihomo", mode: mode, ports: [2080, 2081, 9090], apiPort: 9090, secret: secret) }
do { try validateMihomo(cached); checks += 1 } catch { fputs("FAIL: private provider cache rejected \(error)\n", stderr); exit(1) }
rejects("TUN remote proxy provider") { var bad = cached; bad["tun"] = ["enable": true]; try validateMihomo(bad, mode: "tun") }
rejects("Mihomo external TLS API") { var bad = cached; bad["external-controller-tls"] = "0.0.0.0:23002"; try validateMihomo(bad) }
rejects("Mihomo missing bundled MMDB") { var bad = cached; bad["geodata-mode"] = false; try validateMihomo(bad) }
rejects("Mihomo nested ASN database") { var bad = cached; bad["sub-rules"] = ["nested": ["IP-ASN,123,DIRECT"]]; try validateMihomo(bad) }
rejects("provider traversal") { var bad = cached; bad["proxy-providers"] = ["subscription": ["type": "http", "path": "../../etc/sudoers"]]; try validateMihomo(bad) }
rejects("provider name traversal") { var bad = cached; bad["proxy-providers"] = ["../../etc": ["type": "http"]]; try validateMihomo(bad) }
rejects("file provider") { var bad = cached; bad["proxy-providers"] = ["subscription": ["type": "file", "path": "providers/a.yaml"]]; try validateMihomo(bad) }

let encoded = try JSONSerialization.data(withJSONObject: valid)
let arguments: [String: Any] = ["protocolVersion": 1, "sessionId": UUID().uuidString, "connectionMode": "proxy", "core": "keqrnel", "configurations": ["keqrnel": String(decoding: encoded, as: UTF8.self)], "socksPort": 2080, "httpPort": 2081, "apiPort": 9090, "apiSecret": secret, "systemProxy": true]
do { _ = try SessionRequest(arguments: arguments); checks += 1 } catch { fputs("FAIL: valid session \(error)\n", stderr); exit(1) }
rejects("retired standalone AWG session") {
    var legacy = arguments
    legacy["core"] = "awg"; legacy["wireproxyInfoPort"] = 9091
    legacy["configurations"] = ["wireproxy": wireproxy]
    _ = try SessionRequest(arguments: legacy)
}
rejects("retired wireproxy core name") { var legacy = arguments; legacy["core"] = "wireproxy"; _ = try SessionRequest(arguments: legacy) }
rejects("retired wireproxy configuration beside a supported core") {
    var legacy = arguments
    legacy["configurations"] = ["keqrnel": String(decoding: encoded, as: UTF8.self), "wireproxy": wireproxy]
    _ = try SessionRequest(arguments: legacy)
}
do {
    _ = try CoreRuntime(root: ServicePaths.root).executable(named: "wireproxy")
    fputs("FAIL: retired core executable accepted\n", stderr); exit(1)
} catch let error as ServiceFailure { expect(error.code == "unsupportedCore", "retired executable rejected before filesystem lookup") }
let awgProxy: [String: Any] = ["name": "proxy", "type": "wireguard", "server": "192.0.2.1", "port": 51820,
    "ip": "10.0.0.2/32", "private-key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "udp": true,
    "peers": [["server": "192.0.2.1", "port": 51820, "public-key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "allowed-ips": ["0.0.0.0/0"]]],
    "amnezia-wg-option": ["version": 3, "jc": 4, "jmin": 40, "jmax": 70, "header-protection-key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]]
for mode in ["proxy", "tun"] {
    let config: [String: Any] = ["external-controller": "127.0.0.1:9090", "secret": secret,
        "geodata-mode": true, "geo-auto-update": false, "proxies": [awgProxy], "tun": ["enable": mode == "tun"]]
    var request = arguments
    request["core"] = "mihomo"; request["connectionMode"] = mode
    request["configurations"] = ["mihomo": String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
    if mode == "tun" { request["contextId"] = "prepared-context"; request["dnsAddress"] = "198.18.0.2" }
    do { let session = try SessionRequest(arguments: request); expect(session.core == "mihomo", "AWG uses normal Mihomo \(mode) session") }
    catch { fputs("FAIL: Mihomo AWG configuration rejected \(error)\n", stderr); exit(1) }
    var unsafe = config; unsafe["command"] = "/bin/sh"
    rejects("AWG does not weaken the privileged command policy") { try validateMihomo(unsafe, mode: mode) }
}
rejects("arbitrary executable core") { var bad = arguments; bad["core"] = "/bin/sh"; _ = try SessionRequest(arguments: bad) }
rejects("duplicate ports") { var bad = arguments; bad["httpPort"] = 2080; _ = try SessionRequest(arguments: bad) }
rejects("protocol mismatch") { var bad = arguments; bad["protocolVersion"] = 2; _ = try SessionRequest(arguments: bad) }
rejects("session path traversal") { var bad = arguments; bad["sessionId"] = "../../etc"; _ = try SessionRequest(arguments: bad) }
rejects("extra configuration") { var bad = arguments; bad["configurations"] = ["keqrnel": String(decoding: encoded, as: UTF8.self), "sh": "bad"]; _ = try SessionRequest(arguments: bad) }
let caller = ClientIdentity(uid: 501, gid: 20, connectionID: 10)
func access(_ method: String, _ args: [String: Any] = [:], authorized: Bool = false, owner: ClientIdentity? = nil, session: String? = nil) throws {
    try SessionAccessPolicy.validate(method: method, arguments: args, identity: caller, tunAuthorized: authorized, owner: owner, activeSessionID: session)
}
try access("startProxySession", arguments); checks += 1
try access("getSession"); checks += 1
try access("stopSession", ["sessionId": "active"], owner: caller, session: "active"); checks += 1
for method in ["prepareNetworkContext", "startSession"] {
    rejects("TUN without grant: \(method)") { try access(method) }
    try access(method, authorized: true); checks += 1
}
for method in ["getSession", "stopSession", "startProxySession"] {
    for owner in [ClientIdentity(uid: 502, gid: 20, connectionID: 11), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
        rejects("foreign session \(method)") { try access(method, arguments, owner: owner, session: "active") }
    }
}
for payload: [String: Any] in [[:], ["sessionId": "old"], ["sessionId": 123]] {
    rejects("stop without exact session") { try access("stopSession", payload, owner: caller, session: "active") }
}
rejects("old session poll") { try access("getSession", ["sessionId": "old"], owner: caller, session: "active") }
rejects("unknown operation") { try access("runCommand", authorized: true) }
rejects("TUN through proxy operation") { var bad = arguments; bad["connectionMode"] = "tun"; try access("startProxySession", bad, authorized: true) }
for key in ["contextId", "dnsAddress"] {
    rejects("Proxy TUN field: \(key)") { var bad = arguments; bad[key] = "172.19.0.2"; try access("startProxySession", bad) }
    rejects("Proxy config TUN field: \(key)") { var bad = arguments; bad[key] = "172.19.0.2"; _ = try SessionRequest(arguments: bad) }
}
rejects("keqrnel TUN in Proxy config") { var bad = valid; bad["inbounds"] = [["type": "tun"]]; try validate(bad) }
rejects("mihomo TUN in Proxy config") { var bad = cached; bad["tun"] = ["enable": true]; try validateMihomo(bad) }
for uid: UInt32 in [0, 1, 499] {
    rejects("Proxy root/system account") { try SessionAccessPolicy.validate(method: "startProxySession", arguments: arguments, identity: ClientIdentity(uid: uid, gid: 0, connectionID: 1), tunAuthorized: true, owner: nil, activeSessionID: nil) }
}
let defaultRequest = try SessionRequest(arguments: arguments)
expect(defaultRequest.blockIpv6Leak == false, "IPv6 protection flag defaults to disabled")
let ipv6: [String: Any] = ["inbounds": [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]]], "route": ["rules": [["ip_cidr": ["::/0"], "outbound": "block"]]], "outbounds": [["type": "block", "tag": "block"]]]
func validateIPv6(_ object: [String: Any], core: String = "keqrnel") throws {
    let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    try ConfigPolicy.validateIPv6Protection(configurations: ["keqrnel": text], core: core, required: true)
}
do { try validateIPv6(ipv6); checks += 1 } catch { fputs("FAIL: valid IPv6 protection \(error)\n", stderr); exit(1) }
rejects("Mihomo IPv6 protection unavailable") { try validateIPv6(ipv6, core: "mihomo") }
rejects("missing IPv6 block rule") { var bad = ipv6; bad["route"] = ["rules": []]; try validateIPv6(bad) }
rejects("conditional IPv6 block rule") { var bad = ipv6; bad["route"] = ["rules": [["ip_cidr": ["::/0"], "outbound": "block", "port": 443]]]; try validateIPv6(bad) }
rejects("missing managed IPv6 address") { var bad = ipv6; bad["inbounds"] = [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30"]]]; try validateIPv6(bad) }
expect(keq_ipv6_route_uses_interface("2001:4860:4860::8888", "keqdis-nonexistent-interface") == 0, "IPv6 route verification fails closed for absent tunnel")
expect(keq_ipv6_route_uses_interface("::1", "lo0") == 1, "read-only RTM_GET identifies real loopback IPv6 route")
for tunnel in ["utun6", "ppp0", "ipsec0"] {
    rejects("other VPN owns lower IPv4 half through \(tunnel)") { try IPv4RouteSnapshot(lowerHalf: tunnel, upperHalf: "en0").validateBeforeStarting(mode: "tun") }
    rejects("other VPN owns upper IPv4 half through \(tunnel)") { try IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: tunnel).validateBeforeStarting(mode: "tun") }
}
do {
    try IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: "en1").validateBeforeStarting(mode: "tun"); checks += 1
    try IPv4RouteSnapshot(lowerHalf: "utun6", upperHalf: "utun6").validateBeforeStarting(mode: "proxy"); checks += 1
    try IPv4RouteSnapshot(lowerHalf: nil, upperHalf: nil).validateBeforeStarting(mode: "proxy"); checks += 1
} catch { fputs("FAIL: valid physical/Proxy routing policy \(error)\n", stderr); exit(1) }
rejects("unknown IPv4 routes cannot start TUN") { try IPv4RouteSnapshot(lowerHalf: nil, upperHalf: "en0").validateBeforeStarting(mode: "tun") }
expect(IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun9").usesTunnel("utun9"), "both IPv4 halves enter owned tunnel")
expect(!IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun6").usesTunnel("utun9"), "foreign tunnel is not readiness")
expect(!IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "en0").usesTunnel("utun9"), "half an IPv4 tunnel is not readiness")
expect(!IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: nil).usesTunnel("utun9"), "missing IPv4 route fails closed")
expect(!IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: "en0").usesTunnel("en0"), "physical interface is not an owned tunnel")
expect(IPv4RouteSnapshot.interface(for: "127.0.0.1") == "lo0", "read-only IPv4 lookup skips host route and finds loopback subnet")
expect(IPv4RouteSnapshot.interface(for: "not-an-ip") == nil, "IPv4 lookup rejects nonliteral input")
let journal: [String: Any] = ["directory": UUID().uuidString, "processes": [["name": "keqrnel", "pid": 200, "startTime": UInt64(123456), "executable": ServicePaths.root.appendingPathComponent("bin/keqrnel").path]]]
do { _ = try SessionRecoveryJournal(dictionary: journal, root: ServicePaths.root); checks += 1 } catch { fputs("FAIL: valid journal \(error)\n", stderr); exit(1) }
rejects("missing process journal array") { _ = try SessionRecoveryJournal(dictionary: ["directory": UUID().uuidString], root: ServicePaths.root) }
rejects("journal path traversal") { var bad = journal; bad["directory"] = "../../etc"; _ = try SessionRecoveryJournal(dictionary: bad, root: ServicePaths.root) }
rejects("journal PID overflow") { var bad = journal; var records = journal["processes"] as! [[String: Any]]; records[0]["pid"] = Int.max; bad["processes"] = records; _ = try SessionRecoveryJournal(dictionary: bad, root: ServicePaths.root) }
rejects("journal arbitrary executable") { var bad = journal; var records = journal["processes"] as! [[String: Any]]; records[0]["executable"] = "/bin/sh"; bad["processes"] = records; _ = try SessionRecoveryJournal(dictionary: bad, root: ServicePaths.root) }

// Interface recovery uses synthetic snapshots and a virtual clock. Never create
// a utun, stop another VPN, or issue a routing-table mutation in these checks.
let tunnelIdentity = try TunnelInterfaceIdentity(name: "utun9", index: 42)
let legacyJournal = try SessionRecoveryJournal(dictionary: journal, root: ServicePaths.root)
var oldWireproxyJournal = journal
oldWireproxyJournal["processes"] = [["name": "wireproxy", "pid": 1234, "startTime": UInt64(42), "executable": ServicePaths.root.appendingPathComponent("bin/wireproxy").path]]
let recoveredWireproxy = try SessionRecoveryJournal(dictionary: oldWireproxyJournal, root: ServicePaths.root)
expect(recoveredWireproxy.processes.first?.executable == ServicePaths.root.appendingPathComponent("bin/wireproxy").path, "legacy wireproxy journal remains readable for recovery")
expect(legacyJournal.tunnelInterface == nil, "old journal has no tunnel identity")
var tunnelJournal = journal
tunnelJournal["tunnelInterface"] = tunnelIdentity.dictionary
let restoredTunnelJournal = try SessionRecoveryJournal(dictionary: tunnelJournal, root: ServicePaths.root)
expect(restoredTunnelJournal.tunnelInterface == tunnelIdentity, "journal round-trips tunnel name and index")
for invalid in [NSNull(), ["name": "en0", "index": 42], ["name": "utun9", "index": 0], ["name": "utun../9", "index": 42], ["name": "utun9"]] as [Any] {
    rejects("corrupt tunnel identity") { var bad = journal; bad["tunnelInterface"] = invalid; _ = try SessionRecoveryJournal(dictionary: bad, root: ServicePaths.root) }
}
for index in [true, -1, Int.max, 1.5] as [Any] {
    rejects("noninteger or out-of-range tunnel index") { var bad = journal; bad["tunnelInterface"] = ["name": "utun9", "index": index]; _ = try SessionRecoveryJournal(dictionary: bad, root: ServicePaths.root) }
}
var recoveryTime: TimeInterval = 0
var interfaceSamples = [["utun9": UInt32(42), "utun6": UInt32(7)], ["utun9": UInt32(43), "utun6": UInt32(7)]]
try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, timeout: 1, snapshot: { interfaceSamples.removeFirst() }, routes: { [43] }, now: { recoveryTime }, sleep: { recoveryTime += $0 })
expect(interfaceSamples.isEmpty && recoveryTime > 0, "wait for own utun disappearance without waiting for same-name replacement")
try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, snapshot: { ["utun6": 7] }, routes: { [7] })
checks += 1
try TunnelInterfaceRecovery.waitUntilRemoved(nil, snapshot: { fputs("FAIL: old journal queried interfaces\n", stderr); exit(1) })
checks += 1
recoveryTime = 0
do {
    try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, timeout: 0.2, snapshot: { ["utun9": 42] }, routes: { [] }, now: { recoveryTime }, sleep: { recoveryTime += $0 })
    fputs("FAIL: live original utun passed recovery\n", stderr); exit(1)
} catch { expect((error as? ServiceFailure)?.code == "recoveryFailed", "live original utun reports recovery failure") }
expect(abs(recoveryTime - 0.2) < 0.001, "interface recovery has bounded wait")
do {
    try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, snapshot: { throw ServiceFailure("synthetic", "unavailable") })
    fputs("FAIL: unreadable interface snapshot passed recovery\n", stderr); exit(1)
} catch { expect((error as? ServiceFailure)?.code == "recoveryFailed", "snapshot errors fail recovery closed") }
recoveryTime = 0
var routeSamples: [Set<UInt32>] = [[42, 7], [42, 7], [7]]
try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, timeout: 1, snapshot: { ["utun6": 7] }, routes: { routeSamples.removeFirst() }, now: { recoveryTime }, sleep: { recoveryTime += $0 })
expect(routeSamples.isEmpty && abs(recoveryTime - 0.1) < 0.001, "interface disappearance alone does not acknowledge pending UP routes")
rejects("old UP routes survive interface disappearance") { try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, timeout: 0, snapshot: { [:] }, routes: { [42] }) }
rejects("unreadable route inventory") { try TunnelInterfaceRecovery.waitUntilRemoved(tunnelIdentity, snapshot: { [:] }, routes: { throw ServiceFailure("synthetic", "unavailable") }) }
var routeHeader = rt_msghdr()
routeHeader.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size)
routeHeader.rtm_version = UInt8(RTM_VERSION)
routeHeader.rtm_type = UInt8(RTM_GET)
routeHeader.rtm_index = 42
routeHeader.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY
let routeBytes = withUnsafeBytes(of: &routeHeader) { Data($0) }
let staticGatewayIndices = try TunnelInterfaceRecovery.routeInterfaceIndices(from: routeBytes)
expect(staticGatewayIndices == [42], "RIB parser includes static gateway routes")
rejects("truncated route dump") { _ = try TunnelInterfaceRecovery.routeInterfaceIndices(from: routeBytes.dropLast()) }
routeHeader.rtm_flags = RTF_STATIC | RTF_GATEWAY
let downIndices = try TunnelInterfaceRecovery.routeInterfaceIndices(from: withUnsafeBytes(of: &routeHeader) { Data($0) })
expect(downIndices.isEmpty, "RIB parser ignores routes already down")
let hostInterfaceIndices = try TunnelInterfaceRecovery.capture()
let hostRouteIndices = try TunnelInterfaceRecovery.captureRouteInterfaceIndices()
expect(hostInterfaceIndices["lo0"].map { hostRouteIndices.contains($0) } == true, "read-only kernel interface and route dumps identify loopback")

var logPipe: [Int32] = [-1, -1]
expect(pipe(&logPipe) == 0 && fcntl(logPipe[0], F_SETFL, O_NONBLOCK) == 0, "create nonblocking synthetic core output pipe")
let logPayload = Data((0..<(12 * 8192)).map { UInt8($0 % 251) })
var writtenLogBytes = 0
var receivedLog = Data()
func produceLogChunk() {
    guard writtenLogBytes < logPayload.count else { return }
    let count = logPayload.withUnsafeBytes { Darwin.write(logPipe[1], $0.baseAddress!.advanced(by: writtenLogBytes), 8192) }
    guard count == 8192 else { fputs("FAIL: synthetic pipe producer\n", stderr); exit(1) }
    writtenLogBytes += count
}
produceLogChunk()
let consumeLog: (Data) -> Void = { data in
    receivedLog.append(data)
    // Refill after each read so the producer never lets the pipe reach EAGAIN.
    produceLogChunk()
}
let firstLogRead = CoreOutputReader.drain(logPipe[0], maximumReads: 8, consume: consumeLog)
expect(firstLogRead == 64 * 1024 && receivedLog.count == firstLogRead, "startup log collection yields after eight reads even with a continuous producer")
let remainingLogRead = CoreOutputReader.drain(logPipe[0], maximumReads: 8, consume: consumeLog)
expect(remainingLogRead == 32 * 1024 && receivedLog == logPayload, "next log collection preserves all unread pipe bytes without loss")
expect(CoreOutputReader.drain(logPipe[0], maximumReads: 8, consume: consumeLog) == 0, "empty nonblocking log pipe returns immediately")
close(logPipe[0]); close(logPipe[1])

// Exercise the real C TCP and UDP DNS probes against local protocol responders.
final class DNSProbeGate {
    private let lock = NSLock()
    private let allowed = DispatchSemaphore(value: 0)
    private var received = false
    private var replied = false
    private var progressCount = 0
    func receivedQuery() { lock.lock(); received = true; lock.unlock() }
    func recordProgress() -> Int {
        lock.lock(); defer { lock.unlock() }
        if received { progressCount += 1 }
        return progressCount
    }
    func releaseReply() { allowed.signal() }
    func waitToReply() -> Bool { allowed.wait(timeout: .now() + 3) == .success }
    func sentReply() { lock.lock(); replied = true; lock.unlock() }
    var hasReplied: Bool { lock.lock(); defer { lock.unlock() }; return replied }
}
func probeDNS(tcp: Bool, validReply: Bool, delay: TimeInterval = 0, fragmentDelay: TimeInterval = 0, timeout: Int32 = 1000, gate: DNSProbeGate? = nil, operation: ((UInt16) -> Bool)? = nil) -> Bool {
    let fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard bound == 0 else { close(fd); return false }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
    let port = UInt16(bigEndian: address.sin_port)
    if tcp { guard listen(fd, 1) == 0 else { close(fd); return false } }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { close(fd); done.signal() }
        var buffer = [UInt8](repeating: 0, count: 512)
        if tcp {
            let peer = accept(fd, nil, nil); guard peer >= 0 else { return }; defer { close(peer) }
            var one: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let count = recv(peer, &buffer, buffer.count, 0)
            guard count >= 14 else { return }
            gate?.receivedQuery()
            if let gate, !gate.waitToReply() { return }
            if validReply { buffer[4] |= 0x80; buffer[5] |= 3 } else { buffer[2] ^= 0xff }
            Thread.sleep(forTimeInterval: delay)
            gate?.sentReply()
            _ = send(peer, buffer, 2, 0)
            Thread.sleep(forTimeInterval: fragmentDelay)
            _ = buffer.withUnsafeBytes { send(peer, $0.baseAddress!.advanced(by: 2), count - 2, 0) }
        } else {
            var remote = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &remote) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard count >= 12 else { return }
            gate?.receivedQuery()
            if let gate, !gate.waitToReply() { return }
            if validReply { buffer[2] |= 0x80; buffer[3] |= 3 } else { buffer[0] ^= 0xff }
            Thread.sleep(forTimeInterval: delay)
            gate?.sentReply()
            _ = withUnsafePointer(to: &remote) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, count, 0, $0, length) } }
        }
    }
    let result = operation?(port) ?? (keq_dns_ready("127.0.0.1", port, tcp ? 1 : 0, timeout) == 1)
    gate?.releaseReply()
    _ = done.wait(timeout: .now() + max(2, delay + fragmentDelay + 1))
    return result
}
expect(probeDNS(tcp: false, validReply: true), "UDP DNS readiness accepts matching DNS response")
expect(probeDNS(tcp: true, validReply: true), "TCP DNS readiness accepts matching framed response")
expect(!probeDNS(tcp: false, validReply: false), "UDP DNS readiness rejects mismatched transaction")
expect(!probeDNS(tcp: true, validReply: false), "TCP DNS readiness rejects mismatched transaction")
expect(!probeDNS(tcp: true, validReply: true, delay: 0.16, fragmentDelay: 0.16, timeout: 250), "TCP DNS fragments share one total deadline")
expect(probeDNS(tcp: false, validReply: true, delay: 0.75, timeout: 2000), "UDP DNS probe retains a slow query beyond 500ms")
expect(probeDNS(tcp: true, validReply: true, delay: 0.1, fragmentDelay: 0.65, timeout: 2000), "TCP DNS probe reads delayed fragments within its deadline")
expect(!probeDNS(tcp: false, validReply: true, delay: 0.35, timeout: 150), "UDP DNS probe rejects a reply after its deadline")
for tcp in [Int32(0), 1] {
    expect(keq_dns_ready("127.0.0.1", 9, tcp, 0) == 0, "DNS probe refuses an exhausted budget")
    expect(keq_dns_ready("127.0.0.1", 9, tcp, -1) == 0, "DNS probe refuses a negative budget")
}
for tcp in [false, true] {
    let gate = DNSProbeGate()
    var observedProgress = 0
    let continued = probeDNS(tcp: tcp, validReply: true, timeout: 2000, gate: gate, operation: { port in
        (try? VirtualDNSReadiness.probe(address: "127.0.0.1", port: port, tcp: tcp, timeoutMilliseconds: 2000, validate: {
            observedProgress = gate.recordProgress()
            if observedProgress >= 2 { gate.releaseReply() }
        })) == true
    })
    expect(continued && observedProgress >= 2, "DNS response waits for repeated health callbacks on the same pending query")
}
for failureCode in ["coreExited", "tunnelInterfaceLost"] {
    let gate = DNSProbeGate()
    var observedCode: String?
    var repliedBeforeAbort = true
    let continued = probeDNS(tcp: failureCode == "coreExited", validReply: true, timeout: 2000, gate: gate, operation: { port in
        do {
            return try VirtualDNSReadiness.probe(address: "127.0.0.1", port: port, tcp: failureCode == "coreExited", timeoutMilliseconds: 2000, validate: {
                if gate.recordProgress() >= 2 { throw ServiceFailure(failureCode, "Synthetic startup identity lost.") }
            })
        } catch let error as ServiceFailure { observedCode = error.code; repliedBeforeAbort = gate.hasReplied; return false }
        catch { return false }
    })
    expect(!continued && observedCode == failureCode && !repliedBeforeAbort, "DNS waiting aborts with the original core/interface failure before the responder is released")
}
var virtualDNSTime: TimeInterval = 0
var virtualDNSCalls: [(Bool, Int32)] = []
do {
    try VirtualDNSReadiness.wait(probe: { tcp, budget in
        virtualDNSCalls.append((tcp, budget))
        let responseDelay = tcp ? 0.6 : 5.3
        virtualDNSTime += min(responseDelay, Double(budget) / 1000)
        return Double(budget) / 1000 >= responseDelay
    }, validate: {}, now: { virtualDNSTime }, sleep: { virtualDNSTime += $0 })
    expect(virtualDNSCalls.count == 2 && virtualDNSTime < 6, "DNS startup retains cold UDP query and then checks TCP")
} catch { expect(false, "DNS startup accepts real-world cold response beyond 500ms") }
virtualDNSTime = 0; virtualDNSCalls = []
do {
    try VirtualDNSReadiness.wait(probe: { tcp, budget in
        virtualDNSCalls.append((tcp, budget)); virtualDNSTime += Double(budget) / 1000
        return false
    }, validate: {}, now: { virtualDNSTime }, sleep: { virtualDNSTime += $0 })
    expect(false, "unresponsive DNS must time out")
} catch let error as ServiceFailure {
    expect(virtualDNSCalls.map { $0.0 } == [false, true], "TCP gets a probe when UDP is unresponsive")
    expect(virtualDNSCalls.map { $0.1 } == [8000, 7000] && virtualDNSTime == 15, "DNS transports share 15s without renewing the budget")
    expect(error.code == "readinessTimeout" && error.message.contains("UDP: not ready") && error.message.contains("TCP: not ready"), "DNS timeout identifies both failed transports")
}
virtualDNSTime = 0; virtualDNSCalls = []
do {
    try VirtualDNSReadiness.wait(probe: { tcp, budget in
        virtualDNSCalls.append((tcp, budget)); virtualDNSTime += tcp ? 0.1 : Double(budget) / 1000
        return tcp
    }, validate: {}, now: { virtualDNSTime }, sleep: { virtualDNSTime += $0 })
    expect(false, "TCP success alone must not report DNS ready")
} catch let error as ServiceFailure {
    expect(error.message.contains("UDP: not ready") && error.message.contains("TCP: ready"), "DNS failure preserves independent TCP success")
    expect(virtualDNSCalls.filter { $0.0 }.count == 1 && virtualDNSTime <= 15, "successful transport is retained while failed UDP retries within the shared budget")
}
virtualDNSTime = 0; virtualDNSCalls = []
do {
    try VirtualDNSReadiness.wait(timeout: 0, probe: { tcp, budget in virtualDNSCalls.append((tcp, budget)); return true }, validate: {}, now: { virtualDNSTime })
    expect(false, "zero overall DNS budget must fail")
} catch { expect(virtualDNSCalls.isEmpty, "exhausted DNS budget emits no probes") }
for failureCode in ["coreExited", "tunnelInterfaceLost"] {
    var alive = true
    virtualDNSCalls = []
    do {
        try VirtualDNSReadiness.wait(probe: { tcp, budget in virtualDNSCalls.append((tcp, budget)); alive = false; return true }, validate: {
            if !alive { throw ServiceFailure(failureCode, "Synthetic startup identity lost.") }
        })
        expect(false, "DNS response cannot hide startup identity loss")
    } catch let error as ServiceFailure {
        expect(error.code == failureCode && virtualDNSCalls.count == 1, "DNS validates core/interface again after each probe")
    }
}
let cleanupRoot = FileManager.default.temporaryDirectory.appendingPathComponent("keqdis-cleanup-\(UUID().uuidString)", isDirectory: true)
let outside = cleanupRoot.appendingPathComponent("outside", isDirectory: true)
let session = cleanupRoot.appendingPathComponent("session", isDirectory: true)
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("escape"), withDestinationURL: outside)
try Data("remove".utf8).write(to: session.appendingPathComponent("temporary"))
expect(keq_remove_tree(session.path) == 0, "remove private session tree without following symlinks")
expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel").path), "session cleanup preserves symlink target")
try FileManager.default.removeItem(at: cleanupRoot)
expect(interfaceCounters("keqdis-nonexistent-interface") == nil, "unknown interface has no fabricated counters")
let expectedDNSFields: [String: [String: Any]] = ["DNS": ["ServerAddresses": ["172.19.0.2"]]]
let settingsReadiness = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: expectedDNSFields)
let committedDNS: [String: [String: Any]] = ["primary/DNS": ["ServerAddresses": ["172.19.0.2"]]]
let pendingSettings = NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committedDNS, enabled: ["primary/DNS"], effective: [:])
let readySettings = NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committedDNS, enabled: ["primary/DNS"], effective: expectedDNSFields)
var settingsSamples = [pendingSettings, readySettings]
var settingsTime: TimeInterval = 0
try settingsReadiness.wait(timeout: 1, capture: { settingsSamples.removeFirst() }, now: { settingsTime }, sleep: { settingsTime += $0 })
expect(settingsSamples.isEmpty && settingsTime == 0.05, "settings wait for effective state after commit")
rejects("effective settings never activate") { try settingsReadiness.wait(timeout: 0, capture: { pendingSettings }) }
let foreignDNS: [String: Any] = ["ServerAddresses": ["192.168.1.53"]]
rejects("third-party committed DNS edit") { try settingsReadiness.wait(capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/DNS": foreignDNS], enabled: ["primary/DNS"], effective: expectedDNSFields) }) }
expect(restoreFields(current: foreignDNS, changes: ["ServerAddresses": FieldChange(before: nil, applied: ["172.19.0.2"])])["ServerAddresses"] as? [String] == ["192.168.1.53"], "failed readiness preserves third-party DNS edit")
rejects("primary service changed before activation") { try settingsReadiness.wait(capture: { NetworkSettingsObservation(primaryService: "other", primaryInterface: "en1", committed: committedDNS, enabled: ["primary/DNS"], effective: expectedDNSFields) }) }
rejects("committed DNS protocol disabled") { try settingsReadiness.wait(capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committedDNS, enabled: [], effective: expectedDNSFields) }) }
let proxyFields = NetworkSettingsReadiness.managedFields(proxyPorts: (32080, 32081), dnsAddress: nil)
let proxyReadiness = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: proxyFields)
var effectiveProxy = proxyFields["Proxies"]!
effectiveProxy.removeValue(forKey: "ProxyAutoConfigEnable"); effectiveProxy.removeValue(forKey: "ProxyAutoDiscoveryEnable")
try proxyReadiness.wait(timeout: 0, capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/Proxies": proxyFields["Proxies"]!], enabled: ["primary/Proxies"], effective: ["Proxies": effectiveProxy]) })
checks += 1
effectiveProxy["HTTPPort"] = 2081
rejects("effective proxy uses stale default port") { try proxyReadiness.wait(timeout: 0, capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/Proxies": proxyFields["Proxies"]!], enabled: ["primary/Proxies"], effective: ["Proxies": effectiveProxy]) }) }
var systemDNSTime: TimeInterval = 0
var queriedNames: [String] = []
var queryDeadlines: [TimeInterval] = []
try SystemDNSReadiness.verify(now: { systemDNSTime }, query: { name, remaining in
    queriedNames.append(name); queryDeadlines.append(remaining); systemDNSTime += 2
    return queriedNames.count == 1 ? .negative : .positive
})
expect(queriedNames.count == 2 && queriedNames[0].hasSuffix(".example.com.") && queriedNames[0] != "example.com." && queriedNames[1] == "example.com.", "negative random DNS probe requires positive reserved-domain fallback")
expect(queryDeadlines == [5, 3], "system DNS queries share one five-second budget")
rejects("negative fallback is not DNS health") { try SystemDNSReadiness.verify(query: { _, _ in .negative }) }
rejects("system resolver failure") { try SystemDNSReadiness.verify(query: { _, _ in throw ServiceFailure("synthetic", "server failure") }) }
systemDNSTime = 0
var timedQueryCalls = 0
rejects("expired DNS budget prevents another query") { try SystemDNSReadiness.verify(now: { systemDNSTime }, query: { _, _ in timedQueryCalls += 1; systemDNSTime = 5; return .negative }) }
expect(timedQueryCalls == 1, "expired shared deadline cancels fallback")
let positiveDNS = try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 4)
expect(positiveDNS == .positive, "system DNS accepts valid positive A record")
let negativeDNS = try SystemDNSReadiness.interpret(error: Int32(kDNSServiceErr_NoSuchRecord), added: false, type: 0, recordClass: 0, length: 0)
expect(negativeDNS == .negative, "NoSuchRecord remains an ambiguous negative result")
rejects("system DNS callback timeout") { _ = try SystemDNSReadiness.interpret(error: Int32(kDNSServiceErr_Timeout), added: false, type: 0, recordClass: 0, length: 0) }
rejects("system DNS callback server failure") { _ = try SystemDNSReadiness.interpret(error: Int32(kDNSServiceErr_Transient), added: false, type: 0, recordClass: 0, length: 0) }
rejects("malformed positive DNS record") { _ = try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 0) }
let absentLocalDNSName = "keqdis-local-check-\(UUID().uuidString.lowercased()).invalid."
do {
    _ = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 0.25, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), flags: DNSServiceFlags(kDNSServiceFlagsTimeout))
    expect(false, "legacy flags must suppress absent LocalOnly record callbacks")
} catch let error as ServiceFailure {
    expect(error.code == "systemDNSUnavailable" && error.message.contains("timed out"), "legacy flags suppress absent LocalOnly record until wrapper deadline")
}
do {
    let localNegative = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly))
    expect(localNegative == .negative, "production flags deliver LocalOnly negative answer without public DNS")
} catch {
    expect(false, "production flags must deliver LocalOnly negative answer: \(error.localizedDescription)")
}
do {
    let intermediateCNAME = try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 1, length: 13)
    expect(intermediateCNAME == nil, "intermediate CNAME is followed without declaring A readiness")
} catch {
    expect(false, "intermediate CNAME must be followed: \(error.localizedDescription)")
}
let aAfterCNAME = try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 4)
expect(aAfterCNAME == .positive, "A answer after CNAME completes readiness")
rejects("empty intermediate CNAME") { _ = try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 1, length: 0) }
rejects("non-IN intermediate CNAME") { _ = try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 3, length: 13) }
for fallback in [false, true] {
    var queryCount = 0
    do {
        try SystemDNSReadiness.verify(query: { _, _ in
            queryCount += 1
            if fallback && queryCount == 1 { return .negative }
            throw ServiceFailure("systemDNSUnavailable", "System DNS resolution timed out.")
        })
        expect(false, "system DNS transport failure must fail verification")
    } catch let error as ServiceFailure {
        expect(error.code == "systemDNSUnavailable" && error.message.contains(fallback ? "positive fallback" : "initial randomized probe"), "system DNS timeout identifies query phase and preserves error code")
    }
}
let systemDNSCaller = pthread_self()
for failureCode in ["coreExited", "tunnelInterfaceLost"] {
    var progressCalls = 0
    var progressOnCaller = true
    do {
        _ = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), flags: DNSServiceFlags(kDNSServiceFlagsTimeout), progress: {
            progressCalls += 1
            progressOnCaller = progressOnCaller && pthread_equal(pthread_self(), systemDNSCaller) != 0
            if progressCalls == 3 { throw ServiceFailure(failureCode, "Synthetic startup health failure.", stage: "systemDNS") }
        })
        expect(false, "startup health failure must cancel pending system DNS")
    } catch let error as ServiceFailure {
        expect(error.code == failureCode && error.stage == "systemDNS", "pending system DNS preserves specific startup health failure")
    }
    expect(progressCalls == 3 && progressOnCaller, "pending system DNS repeatedly validates on its caller thread")
    let afterCancellation = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly))
    expect(afterCancellation == .negative && progressCalls == 3, "cancelled system DNS context is quiescent before the next query")
}
var completedSystemDNSProgress = 0
let completedSystemDNS = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), progress: { completedSystemDNSProgress += 1 })
expect(completedSystemDNS == .negative && completedSystemDNSProgress >= 2, "completed system DNS validates health before accepting the callback")
var slowSystemDNSProgress = 0
do {
    _ = try SystemDNSReadiness.queryRecord(name: absentLocalDNSName, timeout: 0.01, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), progress: {
        slowSystemDNSProgress += 1
        Thread.sleep(forTimeInterval: 0.03)
    })
    expect(false, "system DNS progress must consume the existing deadline")
} catch let error as ServiceFailure {
    expect(error.code == "systemDNSUnavailable" && slowSystemDNSProgress == 1, "progress cannot renew the system DNS deadline or accept a late callback")
}
let diagnosticOwner = ClientIdentity(uid: 501, gid: 20, connectionID: 10)
let failedDiagnostic: [String: Any] = ["status": "error", "error": "DNS readiness timed out.", "errorCode": "readinessTimeout", "errorStage": "virtualDNS", "log": "last output", "apiSecret": "private", "sessionId": "old", "pids": ["core": 42]]
let stoppedDiagnostic = SessionDiagnostics.snapshot(failedDiagnostic, owner: diagnosticOwner, caller: diagnosticOwner, disconnected: true)
expect(stoppedDiagnostic["status"] as? String == "disconnected", "diagnostics do not keep a stopped session active")
expect(stoppedDiagnostic["log"] as? String == "last output", "failed startup log survives stop")
expect(stoppedDiagnostic["errorStage"] as? String == "virtualDNS", "failure phase survives stop")
expect(Set(stoppedDiagnostic.keys) == ["status", "log", "error", "errorCode", "errorStage"], "stopped diagnostics omit runtime secrets and session identifiers")
expect(NSDictionary(dictionary: stoppedDiagnostic).isEqual(to: SessionDiagnostics.snapshot(stoppedDiagnostic, owner: diagnosticOwner, caller: diagnosticOwner, disconnected: true)), "repeated stop preserves diagnostics")
for caller in [ClientIdentity(uid: 502, gid: 20, connectionID: 10), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
    expect(SessionDiagnostics.snapshot(failedDiagnostic, owner: diagnosticOwner, caller: caller).keys.sorted() == ["status"], "last diagnostics stay with original account and XPC connection")
}
expect(SessionDiagnostics.snapshot(failedDiagnostic, owner: nil, caller: diagnosticOwner).keys.sorted() == ["status"], "unowned diagnostics are never disclosed")
let diagnosticFailure = ServiceFailure("readinessTimeout", "DNS readiness timed out.", stage: "virtualDNS")
let diagnosticClient = NetworkServiceError(response: diagnosticFailure.dictionary)
let diagnosticBridge = NetworkServiceError.bridge(diagnosticClient, method: "startSession")
expect(diagnosticBridge.code == "readinessTimeout", "Flutter receives original service error code")
expect(diagnosticBridge.details == ["serviceCode": "readinessTimeout", "stage": "virtualDNS", "method": "startSession"], "service phase survives envelope and Flutter bridge")
let diagnosticLegacy = NetworkServiceError(response: ["code": "vpnRouteConflict", "message": "Another VPN owns the route."])
expect(diagnosticLegacy.stage == nil, "legacy helper errors remain compatible")
let diagnosticFallback = NetworkServiceError.bridge(NSError(domain: "test", code: 1), method: "getSession")
expect(diagnosticFallback.code == "macos_network" && diagnosticFallback.details == ["method": "getSession"], "unknown errors retain generic fallback without invented details")
let monitorDiagnostic: [String: Any] = ["status": "error", "errorCode": "network_changed", "requiresReconnect": true, "sessionId": "old"]
let monitorRead = SessionDiagnostics.snapshot(monitorDiagnostic, owner: diagnosticOwner, caller: diagnosticOwner)
expect(monitorRead["requiresReconnect"] as? Bool == true, "monitor reconnect request survives getSession diagnostics")
expect(monitorRead["status"] as? String == "error" && monitorRead["sessionId"] == nil, "monitor diagnostics retain error without old session credentials")
let monitorStopped = SessionDiagnostics.snapshot(monitorRead, owner: diagnosticOwner, caller: diagnosticOwner, disconnected: true)
expect(monitorStopped["requiresReconnect"] == nil && monitorStopped["status"] as? String == "disconnected", "explicit stop clears automatic reconnect request")
for caller in [ClientIdentity(uid: 502, gid: 20, connectionID: 10), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
    expect(SessionDiagnostics.snapshot(monitorDiagnostic, owner: diagnosticOwner, caller: caller).keys.sorted() == ["status"], "monitor reconnect request remains private to original account and connection")
}
expect(SessionDiagnostics.snapshot(["requiresReconnect": "true"], owner: diagnosticOwner, caller: diagnosticOwner)["requiresReconnect"] == nil, "reconnect metadata must be a boolean")

checks += runTUNDNSDiagnosticsChecks()
print("Passed \(checks) native network service checks (no privileged operations).")
