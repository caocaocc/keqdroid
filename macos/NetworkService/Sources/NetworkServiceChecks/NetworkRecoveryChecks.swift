import Foundation
import NetworkServiceKit
import KEQNetworkClient
import Darwin
import CNetworkXPC

/// Pure lifecycle fixtures plus sockets bound only for local ownership checks.
/// No service is started; no interface, route or system setting is modified.
func runNetworkRecoveryChecks() -> Int {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fputs("FAIL: recovery \(label)\n", stderr); exit(1) }
        count += 1
    }
    func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); fputs("FAIL: recovery accepted \(label)\n", stderr); exit(1) }
        catch { count += 1 }
    }
    var retries = NetworkRecoverySchedule()
    retries.failed(ServiceFailure("networkSettingsBusy", "busy"), now: 0)
    check(retries.errorCode == "recoveryRequired", "transient failure waits")
    check(!retries.takeDue(now: 1), "no early attempt")
    for (now, next) in [(2.0, 7.0), (7.0, 22.0)] {
        check(retries.takeDue(now: now), "scheduled attempt \(now)")
        check(!retries.takeDue(now: now), "one attempt per deadline")
        retries.failed(ServiceFailure("recoveryFailed", "busy"), now: now)
        check(retries.nextAttempt == next, "next deadline \(next)")
    }
    check(retries.takeDue(now: 22), "last bounded attempt")
    retries.failed(ServiceFailure("recoveryFailed", "busy"), now: 22)
    check(retries.errorCode == "recoveryFailed" && retries.nextAttempt == nil, "exhausted cleanup remains blocked")
    check(!retries.takeDue(now: 999), "polling never restarts exhausted cleanup")
    for code in ["recoveryCorrupt", "unsafeInstallation", "untrustedClient"] {
        retries.reset(); retries.failed(ServiceFailure(code, "unsafe"), now: 0)
        check(retries.errorCode == code && retries.nextAttempt == nil, "unsafe state has no automatic attempt")
    }
    retries.reset(); check(retries.errorCode == nil && retries.nextAttempt == nil, "explicit retry clears budget")
    let unsafe = NetworkRecoverySchedule.preferredFailure(ServiceFailure("recoveryFailed", "timeout"), ServiceFailure("recoveryCorrupt", "invalid")) as? ServiceFailure
    check(unsafe?.code == "recoveryCorrupt", "journal corruption overrides earlier transient cleanup error")
    let before = NetworkClockSample(continuous: 10, awake: 10)
    check(!NetworkClockSample(continuous: 40, awake: 40).resumed(after: before), "queue delay is not sleep")
    check(NetworkClockSample(continuous: 40, awake: 11).resumed(after: before), "sleep clock gap triggers wake")
    check(!NetworkClockSample(continuous: 10.5, awake: 10.5).resumed(after: before), "normal timer is not sleep")
    let owner = ClientIdentity(uid: 501, gid: 20, connectionID: 10)
    let next = ClientIdentity(uid: 501, gid: 20, connectionID: 11)
    check(!SessionAccessPolicy.isBusy(owner: owner, caller: owner), "same identity not busy")
    check(SessionAccessPolicy.isBusy(owner: owner, caller: next), "same UID different connection busy")
    func access(_ method: String, _ caller: ClientIdentity, disconnected: Bool, pending: Bool, arguments: [String: Any] = [:]) throws {
        try SessionAccessPolicy.validate(method: method, arguments: arguments, identity: caller, tunAuthorized: true, owner: owner, activeSessionID: "old", ownerDisconnected: disconnected, recoveryPending: pending)
    }
    do { try access("stopSession", next, disconnected: true, pending: true); count += 1 }
    catch { fputs("FAIL: native-confirmed residual cleanup denied\n", stderr); exit(1) }
    rejects("live connection residual cleanup") { try access("stopSession", next, disconnected: false, pending: true) }
    rejects("missing recovery flag") { try access("stopSession", next, disconnected: true, pending: false) }
    rejects("foreign UID cleanup") { try access("stopSession", ClientIdentity(uid: 502, gid: 20, connectionID: 11), disconnected: true, pending: true) }
    rejects("residual diagnostic access") { try access("getSession", next, disconnected: true, pending: true) }
    rejects("residual start") { try access("startSession", next, disconnected: true, pending: true) }
    rejects("client self-reported disconnect") { try access("clientDisconnected", owner, disconnected: false, pending: false) }
    rejects("stale session ID") { try access("stopSession", next, disconnected: true, pending: true, arguments: ["sessionId": "wrong"]) }
    let source: [String: Any] = ["status": "error", "sessionId": "old", "connectionMode": "tun", "helperEpoch": "epoch", "requiresReconnect": true, "recoveryRequired": false, "apiSecret": "private", "log": "private"]
    let finished = SessionDiagnostics.snapshot(source, owner: owner, caller: owner)
    check(finished["sessionId"] as? String == "old" && finished["connectionMode"] as? String == "tun", "same-owner completion retains session identity")
    check(finished["apiSecret"] == nil, "completed session removes credentials")
    let foreign = SessionDiagnostics.snapshot(source, owner: owner, caller: next)
    check(foreign["sessionId"] == nil && foreign["log"] == nil, "new connection cannot read completion identity or logs")
    check(SessionDiagnostics.snapshot(source, owner: owner, caller: owner, disconnected: true)["requiresReconnect"] == nil, "explicit stop cancels reconnect")

    func semantic(dns: [String] = ["192.0.2.1"], address: String = "192.0.2.2", lease: Int = 1, ipv6: String = "2001:db8::1", active: Bool = true) -> NetworkSemanticState {
        NetworkSemanticState(interface: "en0", service: "wifi", ipv4: ["Addresses": [address], "Router": "192.0.2.1", "LeaseExpirationTime": lease], ipv6: ["Addresses": [ipv6], "Router": "fe80::1"], link: ["Active": active], dns: dns, hasIPv6: true)
    }
    let base = semantic()
    check(base.revision == semantic(lease: 999, ipv6: "2001:db8::2").revision, "lease and temporary IPv6 rotation do not change revision")
    check(base.revision != semantic(dns: ["192.0.2.3"]).revision, "DNS changes revision")
    check(base.revision != semantic(address: "192.0.2.4").revision, "IPv4 changes revision")
    let physical = IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: "en0")
    let offline = NetworkAvailability.evaluate(nil, routes: IPv4RouteSnapshot(lowerHalf: nil, upperHalf: nil))
    check(offline.proxy.state == "wait" && offline.tun.reason == "physicalNetworkUnavailable", "offline is not VPN conflict")
    let nodns = NetworkAvailability.evaluate(semantic(dns: []), routes: physical)
    check(nodns.proxy.state == "ready" && nodns.tun.reason == "physicalDNSUnavailable", "proxy readiness does not require TUN DNS")
    let vpn = NetworkAvailability.evaluate(base, routes: IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun9"))
    check(vpn.proxy.state == "ready" && vpn.tun.reason == "vpnRouteConflict", "VPN conflict is TUN specific")
    let own = NetworkAvailability.evaluate(base, routes: IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun9"), ownTunnel: "utun9")
    check(own.tun.state == "ready", "own TUN is excluded from foreign conflict")
    check(NetworkAvailability.evaluate(semantic(active: false), routes: physical).proxy.state == "wait", "link down waits")

    for method in ["startSession", "startProxySession"] {
        for code in ["timeout", "serviceInterrupted", "serviceInvalidated", "serviceUnavailable", "invalidResponse"] {
            check(NetworkServiceClient.classify(NetworkServiceError(code: code, message: "lost"), method: method).code == "requestOutcomeUnknown", "mutation reply loss requires reconciliation")
        }
    }
    check(NetworkServiceClient.classify(NetworkServiceError(code: "serviceInvalidated", message: "lost"), method: "getServiceStatus").code == "serviceInvalidated", "read request keeps transport classification")
    check(NetworkServiceClient.classify(NetworkServiceError(code: "unsafeConfiguration", message: "invalid"), method: "startSession").code == "unsafeConfiguration", "definitive rejection not unknown")

    func localListener(_ host: in_addr_t) -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = host
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard fd >= 0, result == 0, listen(fd, 1) == 0 else { fputs("FAIL: temporary listener fixture\n", stderr); exit(1) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
    let loopback = localListener(INADDR_LOOPBACK.bigEndian)
    check(keq_process_lan_listener(getpid(), loopback.1) == 0, "loopback listener is not LAN ready")
    close(loopback.0)
    let wildcard = localListener(INADDR_ANY.bigEndian)
    check(keq_process_lan_listener(getpid(), wildcard.1) == 1, "owned IPv4 wildcard listener is LAN ready")
    check(keq_lan_port_available(wildcard.1) == 0, "occupied wildcard port cannot be allocated")
    check(keq_process_lan_listener(-1, wildcard.1) == 0, "another process cannot satisfy LAN readiness")
    close(wildcard.0)
    check(keq_process_lan_listener(getpid(), wildcard.1) == 0, "closed listener is not ready")
    return count
}
