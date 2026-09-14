import XCTest
@testable import NetworkServiceKit

final class TUNDNSDiagnosticsTests: XCTestCase {
    func testReturnsBeforeDNSAndReportsWarningWithoutSessionFailure() {
        let state = DispatchQueue(label: "test.dns.state")
        let workers = DispatchQueue(label: "test.dns.workers", attributes: .concurrent)
        let diagnostics = TUNDNSDiagnostics(stateQueue: state, workerQueue: workers)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "diagnostics completed")
        var snapshots: [[String: Any]] = []
        state.sync {
            diagnostics.start(sessionID: "session", address: "172.19.0.2", probe: { check, address, timeout, progress in
                XCTAssertEqual(address, "172.19.0.2")
                XCTAssertGreaterThan(timeout, check == .systemDNS ? 4 : 14)
                XCTAssertLessThanOrEqual(timeout, check == .systemDNS ? 5 : 15)
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw ServiceFailure("test", "not released") }
                try progress()
                if check == .systemDNS { throw ServiceFailure("systemDNSUnavailable", "resolver unreachable") }
            }) { result in
                snapshots.append(result)
                if result["status"] as? String != "checking" { finished.fulfill() }
            }
        }
        for _ in 0..<3 { XCTAssertEqual(entered.wait(timeout: .now() + 2), .success) }
        state.sync {
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(snapshots.first?["status"] as? String, "checking")
        }
        for _ in 0..<3 { release.signal() }
        wait(for: [finished], timeout: 2)
        state.sync {
            XCTAssertEqual(snapshots.last?["status"] as? String, "warning")
            XCTAssertEqual(snapshots.last?["sessionId"] as? String, "session")
            XCTAssertEqual((snapshots.last?["systemDNS"] as? [String: String])?["message"], "resolver unreachable")
            XCTAssertEqual((snapshots.last?["virtualTCP"] as? [String: String])?["status"], "ok")
            diagnostics.cancel()
        }
    }

    func testStopAndReconnectRejectOldCompletionEvenWithTheSameSessionID() {
        let state = DispatchQueue(label: "test.dns.state")
        let workers = DispatchQueue(label: "test.dns.workers", attributes: .concurrent)
        let diagnostics = TUNDNSDiagnostics(stateQueue: state, workerQueue: workers)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "new session completed")
        var oldUpdates = 0, newUpdates = 0
        state.sync {
            diagnostics.start(sessionID: "reused", address: "172.19.0.2", probe: { _, _, _, _ in
                entered.signal(); _ = release.wait(timeout: .now() + 3)
            }) { _ in oldUpdates += 1 }
        }
        for _ in 0..<3 { XCTAssertEqual(entered.wait(timeout: .now() + 2), .success) }
        let started = ProcessInfo.processInfo.systemUptime
        state.sync {
            diagnostics.cancel()
            diagnostics.start(sessionID: "reused", address: "198.18.0.2", probe: { _, _, _, _ in }) { result in
                newUpdates += 1
                if result["status"] as? String == "ok" { finished.fulfill() }
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.25)
        wait(for: [finished], timeout: 2)
        for _ in 0..<3 { release.signal() }
        workers.sync(flags: .barrier) {}
        state.sync {
            XCTAssertEqual(oldUpdates, 1)
            XCTAssertEqual(newUpdates, 2)
            diagnostics.cancel()
        }
    }

    func testCancelStopsActiveProbeProgress() {
        let state = DispatchQueue(label: "test.dns.state")
        let workers = DispatchQueue(label: "test.dns.workers", attributes: .concurrent)
        let diagnostics = TUNDNSDiagnostics(stateQueue: state, workerQueue: workers)
        let entered = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        var updates = 0
        state.sync {
            diagnostics.start(sessionID: "cancel", address: "172.19.0.2", probe: { _, _, _, progress in
                defer { exited.signal() }
                entered.signal()
                while true { try progress(); Thread.sleep(forTimeInterval: 0.01) }
            }) { _ in updates += 1 }
        }
        for _ in 0..<3 { XCTAssertEqual(entered.wait(timeout: .now() + 2), .success) }
        state.sync { diagnostics.cancel() }
        for _ in 0..<3 { XCTAssertEqual(exited.wait(timeout: .now() + 0.5), .success) }
        workers.sync(flags: .barrier) {}
        state.sync { XCTAssertEqual(updates, 1) }
    }

    func testRetiredAWGCannotStartButItsRecoveryRecordStillDecodes() throws {
        let request: [String: Any] = ["protocolVersion": 1, "sessionId": UUID().uuidString, "connectionMode": "proxy", "core": "awg"]
        XCTAssertThrowsError(try SessionRequest(arguments: request)) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsupportedCore")
        }
        XCTAssertThrowsError(try CoreRuntime(root: ServicePaths.root).executable(named: "wireproxy")) {
            XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsupportedCore")
        }
        let path = ServicePaths.root.appendingPathComponent("bin/wireproxy").path
        let record: [String: Any] = ["directory": UUID().uuidString,
            "processes": [["name": "wireproxy", "pid": 1234, "startTime": UInt64(42), "executable": path]]]
        XCTAssertEqual(try SessionRecoveryJournal(dictionary: record, root: ServicePaths.root).processes.first?.executable, path)
    }
}
