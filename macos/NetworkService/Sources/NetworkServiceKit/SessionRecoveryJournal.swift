import Foundation
import Darwin

/// Strictly parse recovery records before taking any process action. Corrupt or
/// unknown records must block service startup instead of discarding evidence.
public struct SessionRecoveryJournal {
    public struct ProcessIdentity {
        public let pid: pid_t
        public let startTime: UInt64
        public let executable: String
    }
    public let directory: String
    public let processes: [ProcessIdentity]

    public init(dictionary: [String: Any], root: URL) throws {
        guard let directory = dictionary["directory"] as? String, UUID(uuidString: directory) != nil,
              let records = dictionary["processes"] as? [[String: Any]], records.count <= 2 else {
            throw ServiceFailure("recoveryFailed", "The session recovery journal is invalid; repair is required before another session can start.")
        }
        var identities: [ProcessIdentity] = []
        var seen: Set<Int> = []
        for record in records {
            guard let pid = record["pid"] as? Int, pid > 1, pid <= Int(Int32.max), seen.insert(pid).inserted,
                  let start = record["startTime"] as? UInt64, start > 0,
                  let name = record["name"] as? String, ["keqrnel", "mihomo", "wireproxy"].contains(name) else {
                throw ServiceFailure("recoveryFailed", "The session journal contains an invalid process identity.")
            }
            let executable = root.appendingPathComponent("bin").appendingPathComponent(name).path
            guard record["executable"] as? String == executable else {
                throw ServiceFailure("recoveryFailed", "The recovery journal references an unexpected executable.")
            }
            identities.append(ProcessIdentity(pid: pid_t(pid), startTime: start, executable: executable))
        }
        self.directory = directory
        processes = identities
    }
}
