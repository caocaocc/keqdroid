import Foundation
import CNetworkXPC

private final class DNSProgressContext {
    let validate: () throws -> Void
    var error: Error?
    init(validate: @escaping () throws -> Void) { self.validate = validate }
}

public enum VirtualDNSReadiness {
    public static func probe(address: String, port: UInt16 = 53, tcp: Bool, timeoutMilliseconds: Int32,
                             validate: @escaping () throws -> Void) throws -> Bool {
        let context = DNSProgressContext(validate: validate)
        let result = withExtendedLifetime(context) {
            keq_dns_ready_with_progress(address, port, tcp ? 1 : 0, timeoutMilliseconds, { pointer in
                guard let pointer else { return 0 }
                let context = Unmanaged<DNSProgressContext>.fromOpaque(pointer).takeUnretainedValue()
                do { try context.validate(); return 1 }
                catch { context.error = error; return 0 }
            }, Unmanaged.passUnretained(context).toOpaque())
        }
        if let error = context.error { throw error }
        return result == 1
    }

    public static func wait(timeout: TimeInterval = 15,
                            probe: (_ tcp: Bool, _ timeoutMilliseconds: Int32) throws -> Bool,
                            validate: () throws -> Void,
                            now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let deadline = now() + timeout
        var ready = [false, false]
        while now() < deadline {
            for index in ready.indices where !ready[index] {
                try validate()
                // Cold bootstrap plus proxied DoH can take several seconds.
                // Keep each query alive, reserving time for the other transport.
                let remaining = min(8, max(0, deadline - now()))
                let milliseconds = Int32((remaining * 1000).rounded(.down))
                guard milliseconds > 0 else { break }
                ready[index] = try probe(index == 1, milliseconds)
                // A late DNS reply must not hide a dead core or replaced utun.
                try validate()
            }
            if ready.allSatisfy({ $0 }) && now() < deadline { return }
            let remaining = deadline - now()
            guard remaining >= 0.001 else { break }
            sleep(min(0.1, remaining))
        }
        let udp = ready[0] ? "ready" : "not ready"
        let tcp = ready[1] ? "ready" : "not ready"
        throw ServiceFailure("readinessTimeout", "Virtual DNS readiness timed out (UDP: \(udp); TCP: \(tcp)).")
    }
}
