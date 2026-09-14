import Foundation
import NetworkServiceKit

private final class DiagnosticClock {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delta: TimeInterval) { lock.lock(); value += delta; lock.unlock() }
}

/// Controlled workers exercise lifecycle races without external DNS or TUN.
func runTUNDNSDiagnosticsChecks() -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        checks += 1
    }
    let state = DispatchQueue(label: "test.dns.state")
    let workers = DispatchQueue(label: "test.dns.workers", attributes: .concurrent)
    let clock = DiagnosticClock()
    let diagnostics = TUNDNSDiagnostics(stateQueue: state, workerQueue: workers, now: clock.read)
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var budgets: [TUNDNSDiagnostics.Check: TimeInterval] = [:]
    var calls: [TUNDNSDiagnostics.Check: Int] = [:]
    var snapshots: [[String: Any]] = []
    state.sync {
        diagnostics.start(sessionID: "healthy", address: "172.19.0.2", probe: { check, address, timeout, progress in
            try progress()
            guard address == "172.19.0.2" else { throw ServiceFailure("test", "wrong virtual address") }
            lock.lock(); budgets[check] = timeout; calls[check, default: 0] += 1; lock.unlock()
            started.signal()
            guard release.wait(timeout: .now() + 2) == .success else { throw ServiceFailure("test", "worker was not released") }
            try progress()
        }) { value in snapshots.append(value); if value["status"] as? String != "checking" { completed.signal() } }
    }
    for _ in 0..<3 { expect(started.wait(timeout: .now() + 2) == .success, "all DNS checks can run concurrently") }
    state.sync {
        expect(snapshots.count == 1 && snapshots[0]["status"] as? String == "checking", "diagnostics return checking without waiting for DNS")
    }
    lock.lock(); let initialBudgets = budgets; lock.unlock()
    expect(initialBudgets[.virtualUDP] == 15 && initialBudgets[.virtualTCP] == 15, "virtual transports share original 15 second upper bound")
    expect(initialBudgets[.systemDNS] == 5, "system resolver retains original five second upper bound")
    for _ in 0..<3 { release.signal() }
    expect(completed.wait(timeout: .now() + 2) == .success, "all successful probes complete")
    state.sync {
        let last = snapshots.last!
        expect(last["status"] as? String == "ok" && last["sessionId"] as? String == "healthy", "healthy diagnostics preserve session identity")
        for check in TUNDNSDiagnostics.Check.allCases {
            expect((last[check.rawValue] as? [String: String])?["status"] == "ok", "healthy diagnostics include each transport result")
        }
    }
    lock.lock(); let counts = calls; lock.unlock()
    expect(counts.values.allSatisfy { $0 == 1 } && counts.count == 3, "each diagnostic probe runs only once")

    snapshots = []
    state.sync {
        diagnostics.start(sessionID: "warning", address: "172.19.0.2", probe: { check, _, _, _ in
            if check == .virtualTCP { throw ServiceFailure("synthetic", "TCP resolver unreachable") }
        }) { value in snapshots.append(value); if value["status"] as? String != "checking" { completed.signal() } }
    }
    expect(completed.wait(timeout: .now() + 2) == .success, "failed DNS probe completes as a diagnostic")
    state.sync {
        let last = snapshots.last!
        expect(last["status"] as? String == "warning", "DNS failure is warning, never a session error")
        expect((last["message"] as? String)?.contains("TCP: TCP resolver unreachable") == true, "top-level diagnostic message identifies the failed transport and cause")
        expect((last["virtualTCP"] as? [String: String])?["message"] == "TCP resolver unreachable", "warning retains actionable transport detail")
        expect((last["virtualUDP"] as? [String: String])?["status"] == "ok", "one failed transport does not hide a healthy transport")
    }

    // Simulate a native probe already returning while stop/reconnect wins on
    // the state queue. Reuse sessionId deliberately: id equality is not enough.
    var oldUpdates = 0, newUpdates = 0
    state.sync {
        diagnostics.start(sessionID: "reused", address: "172.19.0.2", probe: { _, _, _, _ in
            started.signal(); _ = release.wait(timeout: .now() + 2)
        }) { _ in oldUpdates += 1 }
    }
    for _ in 0..<3 { expect(started.wait(timeout: .now() + 2) == .success, "old diagnostic workers started") }
    let stopStarted = ProcessInfo.processInfo.systemUptime
    state.sync {
        diagnostics.cancel()
        diagnostics.start(sessionID: "reused", address: "198.18.0.2", probe: { _, _, _, _ in }) { value in
            newUpdates += 1
            if value["status"] as? String == "ok" { completed.signal() }
        }
    }
    expect(ProcessInfo.processInfo.systemUptime - stopStarted < 0.25, "stop and reconnect do not join blocked DNS probes")
    expect(completed.wait(timeout: .now() + 2) == .success, "new session can finish before old DNS probes return")
    for _ in 0..<3 { release.signal() }
    workers.sync(flags: .barrier) {}
    state.sync {
        expect(oldUpdates == 1 && newUpdates == 2, "old completion cannot overwrite a replacement with the same sessionId")
    }

    let exited = DispatchSemaphore(value: 0)
    var cancelledUpdates = 0
    state.sync {
        diagnostics.start(sessionID: "cancelled", address: "172.19.0.2", probe: { _, _, _, progress in
            defer { exited.signal() }
            started.signal()
            while true { try progress(); Thread.sleep(forTimeInterval: 0.01) }
        }) { _ in cancelledUpdates += 1 }
    }
    for _ in 0..<3 { expect(started.wait(timeout: .now() + 2) == .success, "cancellable probes started") }
    state.sync { diagnostics.cancel() }
    for _ in 0..<3 { expect(exited.wait(timeout: .now() + 0.5) == .success, "progress cancels active DNS work promptly") }
    workers.sync(flags: .barrier) {}
    state.sync { expect(cancelledUpdates == 1, "cancelled session receives no terminal diagnostic") }

    // Delaying a worker cannot renew its deadline or emit network traffic after
    // cancellation. No real fifteen-second sleeps are needed for these cases.
    var expiredUpdates: [[String: Any]] = []
    var unexpectedProbes = 0
    workers.suspend()
    state.sync {
        diagnostics.start(sessionID: "expired", address: "172.19.0.2", probe: { _, _, _, _ in
            lock.lock(); unexpectedProbes += 1; lock.unlock()
        }) { value in expiredUpdates.append(value); if value["status"] as? String != "checking" { completed.signal() } }
    }
    clock.advance(16)
    workers.resume()
    expect(completed.wait(timeout: .now() + 2) == .success, "expired queued diagnostics complete with a warning")
    state.sync { expect(expiredUpdates.last?["status"] as? String == "warning", "late workers cannot report healthy DNS") }
    lock.lock(); let expiredCalls = unexpectedProbes; lock.unlock()
    expect(expiredCalls == 0, "queue delay consumes the shared DNS budget")
    workers.suspend()
    state.sync {
        diagnostics.start(sessionID: "never-started", address: "172.19.0.2", probe: { _, _, _, _ in
            lock.lock(); unexpectedProbes += 1; lock.unlock()
        }) { _ in }
        diagnostics.cancel()
    }
    workers.resume(); workers.sync(flags: .barrier) {}; state.sync {}
    lock.lock(); let cancelledCalls = unexpectedProbes; lock.unlock()
    expect(cancelledCalls == 0, "cancelled queued diagnostics emit no DNS requests")
    return checks
}
