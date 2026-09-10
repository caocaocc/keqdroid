// CLT-compatible native validation runner. No system settings or privileged
// installation are touched. XCTest coverage is also available with full Xcode.
import Foundation
import NetworkServiceKit
import CNetworkXPC
import Darwin

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--validate-request" {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceFailure("invalidRequest", "Request must be an object.") }
        _ = try SessionRequest(arguments: arguments)
        print("{\"valid\":true}")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

var checks = 0
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
do { try ConfigPolicy.validateWireproxy(wireproxy, socksPort: 2080, httpPort: 2081); checks += 1 }
catch { fputs("FAIL: valid wireproxy rejected \(error)\n", stderr); exit(1) }
rejects("wireproxy PostUp hook") { try ConfigPolicy.validateWireproxy(wireproxy + "\nPostUp = /bin/sh", socksPort: 2080, httpPort: 2081) }
rejects("wireproxy LAN listener") { try ConfigPolicy.validateWireproxy(wireproxy.replacingOccurrences(of: "127.0.0.1:2080", with: "0.0.0.0:2080"), socksPort: 2080, httpPort: 2081) }

let secret = "0123456789abcdef"
let valid: [String: Any] = ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]], "inbounds": [["type": "socks", "listen": "127.0.0.1", "listen_port": 2080]], "outbounds": [["type": "direct"]]]
func validate(_ object: [String: Any]) throws { try ConfigPolicy.validateJSON(object, core: "keqrnel", mode: "proxy", ports: [2080, 2081, 9090], apiPort: 9090, secret: secret) }
do { try validate(valid); checks += 1 } catch { fputs("FAIL: valid proxy config \(error)\n", stderr); exit(1) }
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
rejects("arbitrary executable core") { var bad = arguments; bad["core"] = "/bin/sh"; _ = try SessionRequest(arguments: bad) }
rejects("duplicate ports") { var bad = arguments; bad["httpPort"] = 2080; _ = try SessionRequest(arguments: bad) }
rejects("protocol mismatch") { var bad = arguments; bad["protocolVersion"] = 2; _ = try SessionRequest(arguments: bad) }
rejects("session path traversal") { var bad = arguments; bad["sessionId"] = "../../etc"; _ = try SessionRequest(arguments: bad) }
rejects("extra configuration") { var bad = arguments; bad["configurations"] = ["keqrnel": String(decoding: encoded, as: UTF8.self), "sh": "bad"]; _ = try SessionRequest(arguments: bad) }
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

// Exercise the real C TCP and UDP DNS probes against local protocol responders.
func probeDNS(tcp: Bool, validReply: Bool) -> Bool {
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
            let count = recv(peer, &buffer, buffer.count, 0)
            guard count >= 14 else { return }
            if validReply { buffer[4] |= 0x80; buffer[5] |= 3 } else { buffer[2] ^= 0xff }
            _ = send(peer, buffer, count, 0)
        } else {
            var remote = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &remote) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard count >= 12 else { return }
            if validReply { buffer[2] |= 0x80; buffer[3] |= 3 } else { buffer[0] ^= 0xff }
            _ = withUnsafePointer(to: &remote) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buffer, count, 0, $0, length) } }
        }
    }
    let result = keq_dns_ready("127.0.0.1", port, tcp ? 1 : 0, 1000) == 1
    _ = done.wait(timeout: .now() + 2)
    return result
}
expect(probeDNS(tcp: false, validReply: true), "UDP DNS readiness accepts matching DNS response")
expect(probeDNS(tcp: true, validReply: true), "TCP DNS readiness accepts matching framed response")
expect(!probeDNS(tcp: false, validReply: false), "UDP DNS readiness rejects mismatched transaction")
expect(!probeDNS(tcp: true, validReply: false), "TCP DNS readiness rejects mismatched transaction")
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
print("Passed \(checks) native network service checks (no privileged operations).")
