import XCTest
@testable import NetworkServiceKit

final class NetworkRecoveryTests: XCTestCase {
    func testCleanupRetriesAreBoundedAndUnsafeStateStopsImmediately() {
        var retry = NetworkRecoverySchedule()
        retry.failed(ServiceFailure("networkSettingsBusy", "busy"), now: 10)
        XCTAssertFalse(retry.takeDue(now: 11.9))
        XCTAssertTrue(retry.takeDue(now: 12))
        retry.failed(ServiceFailure("recoveryFailed", "transient"), now: 12)
        XCTAssertEqual(retry.nextAttempt, 17)
        XCTAssertTrue(retry.takeDue(now: 17))
        retry.failed(ServiceFailure("recoveryFailed", "transient"), now: 17)
        XCTAssertEqual(retry.nextAttempt, 32)
        XCTAssertTrue(retry.takeDue(now: 32))
        retry.failed(ServiceFailure("recoveryFailed", "transient"), now: 32)
        XCTAssertEqual(retry.errorCode, "recoveryFailed")
        XCTAssertNil(retry.nextAttempt)
        retry.reset()
        retry.failed(ServiceFailure("recoveryCorrupt", "invalid journal"), now: 40)
        XCTAssertEqual(retry.errorCode, "recoveryCorrupt")
        XCTAssertNil(retry.nextAttempt)
    }

    func testOnlySleepClockDifferenceTriggersWake() {
        let before = NetworkClockSample(continuous: 10, awake: 10)
        XCTAssertFalse(NetworkClockSample(continuous: 40, awake: 40).resumed(after: before))
        XCTAssertTrue(NetworkClockSample(continuous: 40, awake: 11).resumed(after: before))
    }

    func testBusyIncludesConnectionAndResidualStopRequiresNativeDisconnect() {
        let owner = ClientIdentity(uid: 501, gid: 20, connectionID: 1)
        let next = ClientIdentity(uid: 501, gid: 20, connectionID: 2)
        XCTAssertTrue(SessionAccessPolicy.isBusy(owner: owner, caller: next))
        XCTAssertThrowsError(try SessionAccessPolicy.validate(method: "stopSession", arguments: [:], identity: next, tunAuthorized: false, owner: owner, activeSessionID: "old"))
        XCTAssertNoThrow(try SessionAccessPolicy.validate(method: "stopSession", arguments: [:], identity: next, tunAuthorized: false, owner: owner, activeSessionID: "old", ownerDisconnected: true, recoveryPending: true))
        XCTAssertThrowsError(try SessionAccessPolicy.validate(method: "getSession", arguments: [:], identity: next, tunAuthorized: false, owner: owner, activeSessionID: "old", ownerDisconnected: true, recoveryPending: true))
        XCTAssertThrowsError(try SessionAccessPolicy.validate(method: "stopSession", arguments: [:], identity: ClientIdentity(uid: 502, gid: 20, connectionID: 2), tunAuthorized: false, owner: owner, activeSessionID: "old", ownerDisconnected: true, recoveryPending: true))
    }

    func testSemanticNetworkRevisionIgnoresLeaseAndTemporaryIPv6Address() {
        let first = NetworkSemanticState(interface: "en0", service: "wifi", ipv4: ["Addresses": ["192.0.2.3"], "Router": "192.0.2.1", "LeaseExpirationTime": 10], ipv6: ["Addresses": ["2001:db8::1"], "Router": "fe80::1"], link: ["Active": true], dns: ["192.0.2.1"], hasIPv6: true)
        let refreshed = NetworkSemanticState(interface: "en0", service: "wifi", ipv4: ["Addresses": ["192.0.2.3"], "Router": "192.0.2.1", "LeaseExpirationTime": 90], ipv6: ["Addresses": ["2001:db8::2"], "Router": "fe80::1"], link: ["Active": true], dns: ["192.0.2.1"], hasIPv6: true)
        XCTAssertEqual(first.revision, refreshed.revision)
        XCTAssertNotEqual(first.revision, first.replacingDNS(["192.0.2.2"]).revision)
    }
}
