import XCTest
@testable import NetworkServiceKit

final class NetworkReadinessTests: XCTestCase {
    func testEffectiveProxyCanOmitDisabledPACFlagsButMustUseActualPorts() throws {
        let fields = NetworkSettingsReadiness.managedFields(proxyPorts: (32080, 32081), dnsAddress: nil)
        let expected = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: fields)
        var effective = fields["Proxies"]!
        effective.removeValue(forKey: "ProxyAutoConfigEnable"); effective.removeValue(forKey: "ProxyAutoDiscoveryEnable")
        try expected.wait(timeout: 0, capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/Proxies": fields["Proxies"]!], enabled: ["primary/Proxies"], effective: ["Proxies": effective]) })
        effective["HTTPPort"] = 2081
        XCTAssertThrowsError(try expected.wait(timeout: 0, capture: { NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/Proxies": fields["Proxies"]!], enabled: ["primary/Proxies"], effective: ["Proxies": effective]) }))
    }
    func testSettingsWaitForEffectiveStateAfterCommit() throws {
        let expected = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: ["DNS": ["ServerAddresses": ["172.19.0.2"]]])
        let committed = ["primary/DNS": ["ServerAddresses": ["172.19.0.2"]]]
        var time: TimeInterval = 0
        var samples = [NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committed, enabled: ["primary/DNS"], effective: [:]),
                       NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committed, enabled: ["primary/DNS"], effective: ["DNS": ["ServerAddresses": ["172.19.0.2"]]])]
        try expected.wait(timeout: 1, capture: { samples.removeFirst() }, now: { time }, sleep: { time += $0 })
        XCTAssertEqual(time, 0.05, accuracy: 0.001)
    }
    func testSettingsRejectUserChangesAndPreserveThemOnRestore() {
        let expected = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: ["DNS": ["ServerAddresses": ["172.19.0.2"]]])
        let changed = ["ServerAddresses": ["192.168.1.53"]]
        let observation = NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: ["primary/DNS": changed], enabled: ["primary/DNS"], effective: ["DNS": ["ServerAddresses": ["172.19.0.2"]]])
        XCTAssertThrowsError(try expected.wait(capture: { observation })) { XCTAssertEqual(($0 as? ServiceFailure)?.code, "networkSettingsChanged") }
        XCTAssertEqual(restoreFields(current: changed, changes: ["ServerAddresses": FieldChange(before: nil, applied: ["172.19.0.2"])])["ServerAddresses"] as? [String], ["192.168.1.53"])
    }
    func testEffectiveSettingsTimeoutAndPrimaryChangeFail() {
        let expected = NetworkSettingsReadiness(primaryService: "primary", primaryInterface: "en0", serviceIDs: ["primary"], fields: ["DNS": ["ServerAddresses": ["172.19.0.2"]]])
        var time: TimeInterval = 0
        let committed = ["primary/DNS": ["ServerAddresses": ["172.19.0.2"]]]
        let stale = NetworkSettingsObservation(primaryService: "primary", primaryInterface: "en0", committed: committed, enabled: ["primary/DNS"], effective: [:])
        XCTAssertThrowsError(try expected.wait(timeout: 0.1, capture: { stale }, now: { time }, sleep: { time += $0 })) { XCTAssertEqual(($0 as? ServiceFailure)?.code, "networkSettingsNotEffective") }
        XCTAssertEqual(time, 0.1, accuracy: 0.001)
        XCTAssertThrowsError(try expected.wait(capture: { NetworkSettingsObservation(primaryService: "other", primaryInterface: "en1", committed: committed, enabled: ["primary/DNS"], effective: [:]) }))
    }
}
