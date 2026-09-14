import XCTest
@testable import NetworkServiceKit

final class SessionAccessPolicyTests: XCTestCase {
    private let caller = ClientIdentity(uid: 501, gid: 20, connectionID: 10)

    private func check(_ method: String, arguments: [String: Any] = [:], authorized: Bool = false, owner: ClientIdentity? = nil, session: String? = nil) throws {
        try SessionAccessPolicy.validate(method: method, arguments: arguments, identity: caller, tunAuthorized: authorized, owner: owner, activeSessionID: session)
    }

    func testProxyDoesNotNeedTUNGrant() {
        XCTAssertNoThrow(try check("startProxySession", arguments: ["connectionMode": "proxy"]))
        XCTAssertNoThrow(try check("getSession"))
        XCTAssertNoThrow(try check("stopSession"))
    }

    func testProxyCannotRequestTunnelOrSystemDNS() {
        for arguments: [String: Any] in [[:], ["connectionMode": "tun"], ["connectionMode": "proxy", "dnsAddress": "172.19.0.2"], ["connectionMode": "proxy", "contextId": "physical-network"]] {
            XCTAssertThrowsError(try check("startProxySession", arguments: arguments))
        }
    }

    func testTUNOperationsStillRequireGrantAndUnknownMethodsStayClosed() {
        for method in ["startSession", "prepareNetworkContext"] {
            XCTAssertThrowsError(try check(method)) { XCTAssertEqual(($0 as? ServiceFailure)?.code, "authorizationRequired") }
            XCTAssertNoThrow(try check(method, authorized: true))
        }
        for authorized in [false, true] {
            XCTAssertThrowsError(try check("runCommand", authorized: authorized)) { XCTAssertEqual(($0 as? ServiceFailure)?.code, "unknownMethod") }
        }
    }

    func testOtherAccountOrConnectionCannotReadStopOrReplaceSession() {
        for owner in [ClientIdentity(uid: 502, gid: 20, connectionID: 11), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
            for method in ["getSession", "stopSession", "startProxySession", "startSession", "prepareNetworkContext"] {
                XCTAssertThrowsError(try check(method, arguments: ["connectionMode": "proxy", "sessionId": "active"], authorized: true, owner: owner, session: "active")) {
                    XCTAssertEqual(($0 as? ServiceFailure)?.code, "busy")
                }
            }
        }
    }

    func testCleanupRequiresExactSessionButRemainsAvailableWithoutGrant() {
        XCTAssertThrowsError(try check("getSession", arguments: ["sessionId": "old"], owner: caller, session: "active"))
        XCTAssertNoThrow(try check("stopSession", arguments: ["sessionId": "active"], owner: caller, session: "active"))
        for arguments: [String: Any] in [[:], ["sessionId": "old"], ["sessionId": 123]] {
            XCTAssertThrowsError(try check("stopSession", arguments: arguments, owner: caller, session: "active")) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "sessionMismatch")
            }
        }
    }

    func testRootAndServiceAccountsCannotStartUnprivilegedProxy() {
        for uid: UInt32 in [0, 1, 499] {
            XCTAssertThrowsError(try SessionAccessPolicy.validate(method: "startProxySession", arguments: ["connectionMode": "proxy"], identity: ClientIdentity(uid: uid, gid: 0, connectionID: 1), tunAuthorized: true, owner: nil, activeSessionID: nil))
        }
    }
}
