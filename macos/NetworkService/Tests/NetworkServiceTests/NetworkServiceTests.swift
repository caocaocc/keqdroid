import XCTest
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
    func testIPv6ProtectionRejectsMissingGuarantees() {
        XCTAssertThrowsError(try ConfigPolicy.validateIPv6Protection(configurations: [:], core: "mihomo", required: true))
        XCTAssertThrowsError(try ConfigPolicy.validateIPv6Protection(configurations: ["keqrnel": "{}"], core: "keqrnel", required: true))
        XCTAssertNoThrow(try ConfigPolicy.validateIPv6Protection(configurations: [:], core: "keqrnel", required: false))
    }
}
