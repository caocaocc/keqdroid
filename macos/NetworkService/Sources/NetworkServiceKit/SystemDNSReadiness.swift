import Foundation
import dnssd

public enum SystemDNSAnswer { case positive, negative }

/// Public mDNSResponder API; no resolver override or private DNS configuration API.
/// NoSuchRecord also represents some upstream failures, including SERVFAIL, on
/// macOS 12 and newer. A negative random probe therefore requires a positive A
/// answer for example.com. Both queries share five seconds. Blocking example.com
/// in user DNS rules can fail readiness; those rules are never rewritten here.
public enum SystemDNSReadiness {
    public static func verify(timeout: TimeInterval = 5,
                              now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                              progress: (() throws -> Void)? = nil,
                              query: ((String, TimeInterval) throws -> SystemDNSAnswer)? = nil) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 5 else { throw failure("Invalid system DNS probe deadline.") }
        let deadline = now() + timeout
        func remaining() throws -> TimeInterval {
            let value = deadline - now()
            guard value > 0 else { throw failure("System DNS resolution timed out.") }
            return value
        }
        let perform = query ?? { try queryRecord(name: $0, timeout: $1, progress: progress) }
        func resolve(_ name: String, phase: String) throws -> SystemDNSAnswer {
            do {
                let answer = try perform(name, remaining())
                _ = try remaining()
                return answer
            } catch let error as ServiceFailure {
                throw ServiceFailure(error.code, "System DNS \(phase) failed: \(error.message)", stage: error.stage)
            }
        }
        let probe = "keqdis-\(UUID().uuidString.lowercased()).example.com."
        let answer = try resolve(probe, phase: "initial randomized probe")
        if answer == .negative {
            guard try resolve("example.com.", phase: "positive fallback for example.com") == .positive else {
                throw failure("System DNS positive fallback returned no A answer for example.com. Check DNS reachability and any user rule blocking the probe domain.")
            }
        }
    }

    public static func interpret(error: Int32, added: Bool, type: UInt16, recordClass: UInt16, length: UInt16) throws -> SystemDNSAnswer? {
        if error == kDNSServiceErr_NoSuchRecord { return .negative }
        guard error == kDNSServiceErr_NoError else { throw failure("System DNS query failed (\(error)); timeout or server failure is not a healthy result.") }
        guard added else { return nil }
        // ReturnIntermediates exposes CNAME referrals before the requested A answer.
        if type == kDNSServiceType_CNAME, recordClass == kDNSServiceClass_IN, length > 0, length <= 255 { return nil }
        guard type == kDNSServiceType_A, recordClass == kDNSServiceClass_IN, length == 4 else { throw failure("System DNS returned a malformed A record.") }
        return .positive
    }

    private static func failure(_ message: String) -> ServiceFailure { ServiceFailure("systemDNSUnavailable", message) }

    private final class Reply {
        let done = DispatchSemaphore(value: 0)
        var result: Result<SystemDNSAnswer, Error>?
        func accept(error: Int32, flags: UInt32, type: UInt16, recordClass: UInt16, length: UInt16) {
            guard result == nil else { return }
            do {
                guard let answer = try SystemDNSReadiness.interpret(error: error, added: flags & UInt32(kDNSServiceFlagsAdd) != 0, type: type, recordClass: recordClass, length: length) else { return }
                result = .success(answer)
            } catch { result = .failure(error) }
            done.signal()
        }
    }

    public static func queryRecord(name: String, timeout: TimeInterval, interfaceIndex: UInt32 = 0,
                                   flags: DNSServiceFlags = DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates),
                                   progress: (() throws -> Void)? = nil) throws -> SystemDNSAnswer {
        guard timeout.isFinite, timeout > 0, timeout <= 5 else { throw failure("Invalid system DNS probe deadline.") }
        let deadline = DispatchTime.now() + timeout
        let replies = DispatchQueue(label: "io.github.caocaocc.keqdroid.system-dns-probe")
        let reply = Reply()
        var reference: DNSServiceRef?
        // Without ReturnIntermediates, authoritative NXDOMAIN is suppressed and
        // the randomized probe cannot reach its positive fallback before timeout.
        let status = DNSServiceQueryRecord(&reference, flags, interfaceIndex, name,
                                          UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                          { _, flags, _, error, _, type, recordClass, length, data, _, context in
            guard let context else { return }
            let state = Unmanaged<Reply>.fromOpaque(context).takeUnretainedValue()
            state.accept(error: error, flags: flags, type: type, recordClass: recordClass, length: data == nil ? 0 : length)
        }, Unmanaged.passUnretained(reply).toOpaque())
        guard status == kDNSServiceErr_NoError, let reference else { throw failure("Cannot start the system DNS query (\(status)).") }
        let scheduled = DNSServiceSetDispatchQueue(reference, replies)
        guard scheduled == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            throw failure("Cannot schedule the system DNS query (\(scheduled)).")
        }
        // The public API requires deallocation on its callback queue. Draining
        // that queue also keeps the unretained callback context alive until all
        // in-flight callbacks have returned, including on deadline expiry.
        defer { replies.sync { DNSServiceRefDeallocate(reference) }; withExtendedLifetime(reply) {} }
        while true {
            // Startup owns core logs on this thread; a single long wait can fill
            // the core's output pipe and prevent its DNS reply from completing.
            try progress?()
            guard DispatchTime.now() < deadline else { throw failure("System DNS resolution timed out.") }
            let nextCheck = min(deadline, DispatchTime.now() + .milliseconds(100))
            if reply.done.wait(timeout: nextCheck) == .success {
                // A ready or failed DNS callback must not hide a lost core/utun.
                try progress?()
                guard DispatchTime.now() < deadline else { throw failure("System DNS resolution timed out.") }
                return try replies.sync { try reply.result!.get() }
            }
        }
    }
}
