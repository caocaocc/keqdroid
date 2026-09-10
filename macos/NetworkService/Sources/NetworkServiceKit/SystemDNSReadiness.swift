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
                              query: ((String, TimeInterval) throws -> SystemDNSAnswer)? = nil) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 5 else { throw failure("Invalid system DNS probe deadline.") }
        let deadline = now() + timeout
        func remaining() throws -> TimeInterval {
            let value = deadline - now()
            guard value > 0 else { throw failure("System DNS resolution timed out.") }
            return value
        }
        let perform = query ?? runQuery
        let probe = "keqdis-\(UUID().uuidString.lowercased()).example.com."
        let answer = try perform(probe, remaining())
        _ = try remaining()
        if answer == .negative {
            guard try perform("example.com.", remaining()) == .positive else {
                throw failure("System DNS returned no positive answer for example.com. Check DNS reachability and any user rule blocking the probe domain.")
            }
            _ = try remaining()
        }
    }

    public static func interpret(error: Int32, added: Bool, type: UInt16, recordClass: UInt16, length: UInt16) throws -> SystemDNSAnswer? {
        if error == kDNSServiceErr_NoSuchRecord { return .negative }
        guard error == kDNSServiceErr_NoError else { throw failure("System DNS query failed (\(error)); timeout or server failure is not a healthy result.") }
        guard added else { return nil }
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

    private static func runQuery(name: String, timeout: TimeInterval) throws -> SystemDNSAnswer {
        let deadline = DispatchTime.now() + timeout
        let replies = DispatchQueue(label: "io.github.caocaocc.keqdroid.system-dns-probe")
        let reply = Reply()
        var reference: DNSServiceRef?
        let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsTimeout), 0, name,
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
        guard reply.done.wait(timeout: deadline) == .success else { throw failure("System DNS resolution timed out.") }
        return try replies.sync { try reply.result!.get() }
    }
}
