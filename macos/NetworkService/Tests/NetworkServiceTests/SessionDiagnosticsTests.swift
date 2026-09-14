import XCTest
import NetworkServiceKit
import KEQNetworkClient

final class SessionDiagnosticsTests: XCTestCase {
    private let owner = ClientIdentity(uid: 501, gid: 20, connectionID: 10)
    private let failed: [String: Any] = ["status": "error", "error": "DNS readiness timed out.", "errorCode": "readinessTimeout", "errorStage": "virtualDNS", "log": "last core output", "sessionId": "old", "apiSecret": "private", "networkContext": ["dnsServers": ["192.0.2.53"]], "pids": ["core": 42]]

    func testStopKeepsFailureDiagnosticsButRemovesSessionCredentials() {
        let stopped = SessionDiagnostics.snapshot(failed, owner: owner, caller: owner, disconnected: true)
        XCTAssertEqual(stopped["status"] as? String, "disconnected")
        XCTAssertEqual(stopped["log"] as? String, "last core output")
        XCTAssertEqual(stopped["errorCode"] as? String, "readinessTimeout")
        XCTAssertEqual(stopped["errorStage"] as? String, "virtualDNS")
        XCTAssertEqual(Set(stopped.keys), ["status", "log", "error", "errorCode", "errorStage", "sessionId"])
        let again = SessionDiagnostics.snapshot(stopped, owner: owner, caller: owner, disconnected: true)
        XCTAssertTrue(NSDictionary(dictionary: stopped).isEqual(to: again))
    }

    func testOtherAccountOrNewConnectionCannotReadStoppedDiagnostics() {
        for caller in [ClientIdentity(uid: 502, gid: 20, connectionID: 10), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
            XCTAssertEqual(SessionDiagnostics.snapshot(failed, owner: owner, caller: caller).keys.sorted(), ["status"])
            XCTAssertEqual(SessionDiagnostics.snapshot(failed, owner: owner, caller: caller)["status"] as? String, "disconnected")
        }
        XCTAssertEqual(SessionDiagnostics.snapshot(failed, owner: nil, caller: owner).keys.sorted(), ["status"])
    }

    func testMonitorReconnectSignalSurvivesReadButNotExplicitStop() {
        let monitored: [String: Any] = ["status": "error", "errorCode": "network_changed", "requiresReconnect": true, "sessionId": "old"]
        let read = SessionDiagnostics.snapshot(monitored, owner: owner, caller: owner)
        XCTAssertEqual(read["requiresReconnect"] as? Bool, true)
        XCTAssertEqual(read["status"] as? String, "error")
        XCTAssertEqual(read["sessionId"] as? String, "old")
        let stopped = SessionDiagnostics.snapshot(read, owner: owner, caller: owner, disconnected: true)
        XCTAssertNil(stopped["requiresReconnect"])
        XCTAssertEqual(stopped["status"] as? String, "disconnected")
        for caller in [ClientIdentity(uid: 502, gid: 20, connectionID: 10), ClientIdentity(uid: 501, gid: 20, connectionID: 11)] {
            XCTAssertEqual(SessionDiagnostics.snapshot(monitored, owner: owner, caller: caller).keys.sorted(), ["status"])
        }
        XCTAssertNil(SessionDiagnostics.snapshot(["requiresReconnect": "true"], owner: owner, caller: owner)["requiresReconnect"])
    }

    func testNativeFailureCodeAndStageSurviveClientBridge() {
        let failure = ServiceFailure("readinessTimeout", "DNS readiness timed out.", stage: "virtualDNS")
        let decoded = NetworkServiceError(response: failure.dictionary)
        XCTAssertEqual(decoded.code, "readinessTimeout")
        XCTAssertEqual(decoded.message, "DNS readiness timed out.")
        XCTAssertEqual(decoded.stage, "virtualDNS")
        let bridged = NetworkServiceError.bridge(decoded, method: "startSession")
        XCTAssertEqual(bridged.code, "readinessTimeout")
        XCTAssertEqual(bridged.details, ["serviceCode": "readinessTimeout", "stage": "virtualDNS", "method": "startSession"])
    }

    func testLegacyAndUnknownErrorsDoNotInventServiceStages() {
        let legacy = NetworkServiceError(response: ["code": "vpnRouteConflict", "message": "Another VPN owns the route."])
        XCTAssertNil(legacy.stage)
        XCTAssertNil(NetworkServiceError.bridge(legacy, method: "prepareNetworkContext").details["stage"])
        let fallback = NetworkServiceError.bridge(NSError(domain: "test", code: 1), method: "getSession")
        XCTAssertEqual(fallback.code, "macos_network")
        XCTAssertEqual(fallback.details, ["method": "getSession"])
    }
}
