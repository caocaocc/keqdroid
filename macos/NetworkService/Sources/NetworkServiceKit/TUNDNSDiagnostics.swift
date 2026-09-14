import Foundation

/// External DNS answers describe connectivity after the local tunnel is ready.
/// They never decide ownership of network settings or stop a running core.
public final class TUNDNSDiagnostics {
    public enum Check: String, CaseIterable {
        case virtualUDP, virtualTCP, systemDNS
    }
    public typealias Probe = (Check, String, TimeInterval, @escaping () throws -> Void) throws -> Void

    private final class Run {
        let sessionID: String
        private let lock = NSLock()
        private var cancelled = false
        private var results: [String: [String: String]] = [:]

        init(sessionID: String) { self.sessionID = sessionID }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func checkCancellation() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw ServiceFailure("dnsDiagnosticCancelled", "TUN DNS diagnostics were cancelled.") }
        }
        func record(_ check: Check, status: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            if !cancelled { results[check.rawValue] = ["status": status, "message": String(message.prefix(1024))] }
        }
        func completedSnapshot() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            let healthy = results.count == Check.allCases.count && results.values.allSatisfy { $0["status"] == "ok" }
            let warnings = Check.allCases.compactMap { check -> String? in
                guard let result = results[check.rawValue], result["status"] == "warning" else { return nil }
                let label = check == .virtualUDP ? "UDP" : (check == .virtualTCP ? "TCP" : "system resolver")
                return "\(label): \(result["message"] ?? "query failed")"
            }
            var snapshot: [String: Any] = [
                "sessionId": sessionID,
                "status": healthy ? "ok" : "warning",
                "message": healthy ? "TUN DNS checks passed." : "TUN DNS warning. " + warnings.joined(separator: "; ")
            ]
            for (key, value) in results { snapshot[key] = value }
            return snapshot
        }
    }

    private let stateQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private let now: () -> TimeInterval
    private var current: Run?

    public init(stateQueue: DispatchQueue,
                workerQueue: DispatchQueue = DispatchQueue(label: "io.github.caocaocc.keqdroid.tun-dns", qos: .utility, attributes: .concurrent),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.stateQueue = stateQueue; self.workerQueue = workerQueue; self.now = now
    }
    deinit { current?.cancel() }

    /// Called once after a TUN session has passed local readiness. All lifecycle
    /// changes and callbacks belong to the service's serial state queue; only
    /// the cancellation token and result collection cross into probe workers.
    public func start(sessionID: String, address: String, probe: @escaping Probe = TUNDNSDiagnostics.liveProbe,
                      onUpdate: @escaping ([String: Any]) -> Void) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        cancel()
        let run = Run(sessionID: sessionID)
        current = run
        onUpdate(["sessionId": sessionID, "status": "checking", "message": "Checking TUN DNS."])
        let started = now(), clock = now
        let group = DispatchGroup()
        for check in Check.allCases {
            group.enter()
            workerQueue.async {
                defer { group.leave() }
                // Preserve the existing upper bounds. Both virtual transports
                // share one 15-second deadline; the system query has 5 seconds.
                // Queueing time counts too. A check runs once, without retries.
                let deadline = started + (check == .systemDNS ? 5 : 15)
                let progress = {
                    try run.checkCancellation()
                    guard clock() < deadline else { throw ServiceFailure("dnsDiagnosticTimeout", "TUN DNS check timed out.") }
                }
                do {
                    try progress()
                    try probe(check, address, max(0, deadline - clock()), progress)
                    try progress()
                    let message = check == .systemDNS ? "TUN DNS system resolution succeeded." : "TUN DNS \(check == .virtualTCP ? "TCP" : "UDP") listener responded."
                    run.record(check, status: "ok", message: message)
                } catch {
                    run.record(check, status: "warning", message: error.localizedDescription)
                }
            }
        }
        group.notify(queue: stateQueue) { [weak self] in
            // Identity matters as well as sessionId: a caller may reconnect
            // using the same id while a cancelled probe is completing.
            guard let self, self.current === run else { return }
            onUpdate(run.completedSnapshot())
        }
    }

    /// No joining, queue drain or DNS work here: stop/reconnect must proceed
    /// while native polls notice cancellation (at most their 100 ms slice).
    public func cancel() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        current?.cancel(); current = nil
    }

    public static func liveProbe(_ check: Check, address: String, timeout: TimeInterval,
                                 progress: @escaping () throws -> Void) throws {
        try progress()
        if check == .systemDNS {
            try SystemDNSReadiness.verify(timeout: min(5, timeout), progress: progress)
        } else {
            let ready = try VirtualDNSReadiness.probe(address: address, tcp: check == .virtualTCP,
                                                      timeoutMilliseconds: Int32(max(1, min(15, timeout) * 1000)), validate: progress)
            guard ready else { throw ServiceFailure("virtualDNSUnavailable", "TUN DNS \(check == .virtualTCP ? "TCP" : "UDP") query did not return a valid answer.") }
        }
    }
}
