import XCTest
import Darwin
@testable import NetworkServiceKit

final class NetworkServiceTests: XCTestCase {
    func testRestoresOnlyUnchangedOwnedFields() {
        let changes = ["HTTPEnable": FieldChange(before: 0, applied: 1), "HTTPProxy": FieldChange(before: nil, applied: "127.0.0.1")]
        let restored = restoreFields(current: ["HTTPEnable": 1, "HTTPProxy": "another-proxy", "Other": 42], changes: changes)
        XCTAssertEqual(restored["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(restored["HTTPProxy"] as? String, "another-proxy")
        XCTAssertEqual(restored["Other"] as? Int, 42)
    }
    func testRestoresAbsentDNSWithoutDeletingOtherSettings() {
        let restored = restoreFields(current: ["ServerAddresses": ["172.19.0.2"], "SearchDomains": ["example.test"]], changes: ["ServerAddresses": FieldChange(before: nil, applied: ["172.19.0.2"])])
        XCTAssertNil(restored["ServerAddresses"])
        XCTAssertEqual(restored["SearchDomains"] as? [String], ["example.test"])
    }
    func testForeignFieldEditPreventsDisablingUpdatedProtocol() {
        let changes = ["ServerAddresses": FieldChange(before: nil, applied: ["172.19.0.2"])]
        XCTAssertTrue(restoreProtocolEnabled(current: true, before: false, fields: ["ServerAddresses": ["192.168.1.1"]], changes: changes))
        XCTAssertFalse(restoreProtocolEnabled(current: true, before: false, fields: ["ServerAddresses": ["172.19.0.2"]], changes: changes))
    }
    func testPhysicalDNSRejectsLoopbackVirtualAndMulticast() {
        for value in ["127.0.0.1", "::1", "172.19.0.2", "198.18.0.2", "fe80::1", "224.0.0.1", "not-a-host"] { XCTAssertFalse(isPhysicalDNSAddress(value), value) }
        for value in ["192.168.1.1", "8.8.8.8", "2001:4860:4860::8888"] { XCTAssertTrue(isPhysicalDNSAddress(value), value) }
    }
    func testWireproxyRejectsRootHooksAndRemoteListeners() throws {
        let valid = "[Interface]\nPrivateKey = example\nAddress = 10.0.0.1/32\n[Peer]\nPublicKey = example\nEndpoint = example.test:1234\n[Socks5]\nBindAddress = 127.0.0.1:2080\n[http]\nBindAddress = 127.0.0.1:2081"
        XCTAssertNoThrow(try ConfigPolicy.validateWireproxy(valid, socksPort: 2080, httpPort: 2081))
        XCTAssertThrowsError(try ConfigPolicy.validateWireproxy(valid + "\nPostUp = /bin/sh", socksPort: 2080, httpPort: 2081))
        XCTAssertThrowsError(try ConfigPolicy.validateWireproxy(valid.replacingOccurrences(of: "127.0.0.1:2080", with: "0.0.0.0:2080"), socksPort: 2080, httpPort: 2081))
    }
    func testRejectsArbitraryRootOutputPathBeforeStartingCore() {
        let payload: [String: Any] = ["log": ["output": "/etc/sudoers"]]
        XCTAssertThrowsError(try ConfigPolicy.validateJSON(payload, core: "keqrnel", mode: "tun", ports: [2080, 2081, 9090], apiPort: 9090, secret: "0123456789abcdef"))
    }
    func testRecoveryJournalRejectsCorruptState() {
        XCTAssertThrowsError(try SessionRecoveryJournal(dictionary: ["directory": UUID().uuidString], root: ServicePaths.root))
        XCTAssertThrowsError(try SessionRecoveryJournal(dictionary: ["directory": "../../etc", "processes": []], root: ServicePaths.root))
        XCTAssertNoThrow(try SessionRecoveryJournal(dictionary: ["directory": UUID().uuidString, "processes": []], root: ServicePaths.root))
    }
    func testRecoveryJournalPreservesTunnelIdentityAndAcceptsOlderRecords() throws {
        let old: [String: Any] = ["directory": UUID().uuidString, "processes": []]
        XCTAssertNil(try SessionRecoveryJournal(dictionary: old, root: ServicePaths.root).tunnelInterface)
        var record = old
        record["tunnelInterface"] = ["name": "utun9", "index": 42]
        let identity = try SessionRecoveryJournal(dictionary: record, root: ServicePaths.root).tunnelInterface
        XCTAssertEqual(identity, try TunnelInterfaceIdentity(name: "utun9", index: 42))
        for invalid in [NSNull(), ["name": "en0", "index": 42], ["name": "utun9", "index": 0], ["name": "utun../9", "index": 42], ["name": "utun9"]] as [Any] {
            record["tunnelInterface"] = invalid
            XCTAssertThrowsError(try SessionRecoveryJournal(dictionary: record, root: ServicePaths.root))
        }
        for index in [true, -1, Int.max, 1.5] as [Any] {
            record["tunnelInterface"] = ["name": "utun9", "index": index]
            XCTAssertThrowsError(try SessionRecoveryJournal(dictionary: record, root: ServicePaths.root))
        }
    }
    func testTunnelRecoveryWaitsForOriginalInterfaceAndIgnoresNameReuse() throws {
        let identity = try TunnelInterfaceIdentity(name: "utun9", index: 42)
        var time: TimeInterval = 0
        var samples = [["utun9": UInt32(42), "utun6": UInt32(7)], ["utun9": UInt32(43), "utun6": UInt32(7)]]
        try TunnelInterfaceRecovery.waitUntilRemoved(identity, timeout: 1, snapshot: { samples.removeFirst() }, routes: { [43] }, now: { time }, sleep: { time += $0 })
        XCTAssertTrue(samples.isEmpty)
        XCTAssertGreaterThan(time, 0)
        XCTAssertNoThrow(try TunnelInterfaceRecovery.waitUntilRemoved(nil, snapshot: { XCTFail("older/proxy journal queried interfaces"); return [:] }))
    }
    func testTunnelRecoveryTimesOutOrReportsUnreadableSnapshot() throws {
        let identity = try TunnelInterfaceIdentity(name: "utun9", index: 42)
        var time: TimeInterval = 0
        XCTAssertThrowsError(try TunnelInterfaceRecovery.waitUntilRemoved(identity, timeout: 0.2, snapshot: { ["utun9": 42] }, routes: { [] }, now: { time }, sleep: { time += $0 })) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "recoveryFailed")
        }
        XCTAssertEqual(time, 0.2, accuracy: 0.001)
        XCTAssertThrowsError(try TunnelInterfaceRecovery.waitUntilRemoved(identity, snapshot: { throw ServiceFailure("synthetic", "unavailable") })) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "recoveryFailed")
        }
        XCTAssertNoThrow(try TunnelInterfaceRecovery.waitUntilRemoved(identity, snapshot: { ["utun6": 7] }, routes: { [7] }))
    }
    func testTunnelRecoveryWaitsForRoutesAfterInterfaceDisappears() throws {
        let identity = try TunnelInterfaceIdentity(name: "utun9", index: 42)
        var time: TimeInterval = 0
        var routes: [Set<UInt32>] = [[42, 7], [42, 7], [7]]
        try TunnelInterfaceRecovery.waitUntilRemoved(identity, timeout: 1, snapshot: { ["utun6": 7] }, routes: { routes.removeFirst() }, now: { time }, sleep: { time += $0 })
        XCTAssertTrue(routes.isEmpty)
        XCTAssertEqual(time, 0.1, accuracy: 0.001)
        XCTAssertThrowsError(try TunnelInterfaceRecovery.waitUntilRemoved(identity, timeout: 0, snapshot: { [:] }, routes: { [42] })) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "recoveryFailed")
        }
        XCTAssertThrowsError(try TunnelInterfaceRecovery.waitUntilRemoved(identity, snapshot: { [:] }, routes: { throw ServiceFailure("synthetic", "unavailable") })) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "recoveryFailed")
        }
    }
    func testRecoveryRouteDumpParserKeepsStaticGatewayRoutesAndRejectsTruncation() throws {
        var message = rt_msghdr()
        message.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size)
        message.rtm_version = UInt8(RTM_VERSION)
        message.rtm_type = UInt8(RTM_GET)
        message.rtm_index = 42
        message.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY
        let bytes = withUnsafeBytes(of: &message) { Data($0) }
        XCTAssertEqual(try TunnelInterfaceRecovery.routeInterfaceIndices(from: bytes), [42])
        XCTAssertThrowsError(try TunnelInterfaceRecovery.routeInterfaceIndices(from: bytes.dropLast()))
        message.rtm_flags = RTF_STATIC | RTF_GATEWAY
        XCTAssertTrue(try TunnelInterfaceRecovery.routeInterfaceIndices(from: withUnsafeBytes(of: &message) { Data($0) }).isEmpty)
    }
    func testIPv6ProtectionRejectsMissingGuarantees() {
        XCTAssertThrowsError(try ConfigPolicy.validateIPv6Protection(configurations: [:], core: "mihomo", required: true))
        XCTAssertThrowsError(try ConfigPolicy.validateIPv6Protection(configurations: ["keqrnel": "{}"], core: "keqrnel", required: true))
        XCTAssertNoThrow(try ConfigPolicy.validateIPv6Protection(configurations: [:], core: "keqrnel", required: false))
    }
    func testTUNRejectsBroadVPNRoutesEvenWithPhysicalDefault() {
        for tunnel in ["utun6", "ppp0", "ipsec0"] {
            XCTAssertThrowsError(try IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: tunnel).validateBeforeStarting(mode: "tun"))
            XCTAssertThrowsError(try IPv4RouteSnapshot(lowerHalf: tunnel, upperHalf: "en0").validateBeforeStarting(mode: "tun"))
        }
        XCTAssertNoThrow(try IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: "en1").validateBeforeStarting(mode: "tun"))
    }
    func testProxyDoesNotClaimOrRequireGlobalIPv4Routes() {
        XCTAssertNoThrow(try IPv4RouteSnapshot(lowerHalf: "utun6", upperHalf: "utun6").validateBeforeStarting(mode: "proxy"))
        XCTAssertNoThrow(try IPv4RouteSnapshot(lowerHalf: nil, upperHalf: nil).validateBeforeStarting(mode: "proxy"))
    }
    func testTUNIPv4ReadinessRequiresBothHalvesOnItsExactInterface() {
        XCTAssertTrue(IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun9").usesTunnel("utun9"))
        XCTAssertFalse(IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "utun6").usesTunnel("utun9"))
        XCTAssertFalse(IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: "en0").usesTunnel("utun9"))
        XCTAssertFalse(IPv4RouteSnapshot(lowerHalf: "utun9", upperHalf: nil).usesTunnel("utun9"))
        XCTAssertFalse(IPv4RouteSnapshot(lowerHalf: "en0", upperHalf: "en0").usesTunnel("en0"))
        XCTAssertThrowsError(try IPv4RouteSnapshot(lowerHalf: nil, upperHalf: "en0").validateBeforeStarting(mode: "tun"))
    }
}
