import Foundation
import CoreFoundation
import Darwin

/// Interface names can be reused after detach. Keep the kernel index as well so
/// a newly created VPN with the same utun name cannot delay this session's exit.
public struct TunnelInterfaceIdentity: Equatable {
    public let name: String
    public let index: UInt32

    public init(name: String, index: UInt32) throws {
        let suffix = name.dropFirst(4)
        guard name.hasPrefix("utun"), !suffix.isEmpty,
              suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              name.utf8.count < Int(IFNAMSIZ), index > 0 else {
            throw ServiceFailure("recoveryFailed", "The session journal contains an invalid tunnel interface identity.")
        }
        self.name = name
        self.index = index
    }

    public init(dictionary: [String: Any]) throws {
        guard let name = dictionary["name"] as? String, let number = dictionary["index"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let index = UInt32(number.stringValue) else {
            throw ServiceFailure("recoveryFailed", "The session journal is missing its tunnel name or interface index.")
        }
        try self.init(name: name, index: index)
    }

    public var dictionary: [String: Any] { ["name": name, "index": index] }
}

public enum TunnelInterfaceRecovery {
    /// Read-only kernel inventory. An unreadable snapshot is never interpreted
    /// as an empty inventory, which would falsely acknowledge successful cleanup.
    public static func capture() throws -> [String: UInt32] {
        guard let first = if_nameindex() else {
            throw ServiceFailure("recoveryFailed", "Cannot read network interface identities (\(errno)).")
        }
        defer { if_freenameindex(first) }
        var result: [String: UInt32] = [:]
        var entry = first
        while entry.pointee.if_index != 0 {
            guard let name = entry.pointee.if_name else {
                throw ServiceFailure("recoveryFailed", "The network interface inventory is incomplete.")
            }
            result[String(cString: name)] = entry.pointee.if_index
            entry = entry.advanced(by: 1)
        }
        return result
    }

    /// NET_RT_DUMP is a read-only sysctl across IPv4/IPv6. Route headers retain
    /// their ifindex while ifnet detach is pending, even when if_nameindex has
    /// already stopped listing the interface. Include static and gateway routes.
    public static func captureRouteInterfaceIndices() throws -> Set<UInt32> {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0]
        for _ in 0..<3 {
            var count = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &count, nil, 0) == 0,
                  count >= 0, count <= 16 * 1024 * 1024 else {
                throw ServiceFailure("recoveryFailed", "Cannot size the route inventory (\(errno)).")
            }
            if count == 0 { return [] }
            var bytes = Data(count: count)
            let result = bytes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &count, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue } // The RIB grew between reads.
                throw ServiceFailure("recoveryFailed", "Cannot read the route inventory (\(errno)).")
            }
            guard count <= bytes.count else {
                throw ServiceFailure("recoveryFailed", "The route inventory changed while being read.")
            }
            bytes.count = count
            return try routeInterfaceIndices(from: bytes)
        }
        throw ServiceFailure("recoveryFailed", "The route inventory did not stabilize during recovery.")
    }

    public static func routeInterfaceIndices(from data: Data) throws -> Set<UInt32> {
        try data.withUnsafeBytes { bytes in
            var indices: Set<UInt32> = []
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= MemoryLayout<rt_msghdr>.size else {
                    throw ServiceFailure("recoveryFailed", "The route inventory has a truncated header.")
                }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length >= MemoryLayout<rt_msghdr>.size, length <= bytes.count - offset,
                      header.rtm_version == RTM_VERSION, header.rtm_type == RTM_GET else {
                    throw ServiceFailure("recoveryFailed", "The route inventory contains an invalid record.")
                }
                if header.rtm_flags & RTF_UP != 0, header.rtm_index != 0 {
                    indices.insert(UInt32(header.rtm_index))
                }
                offset += length
            }
            return indices
        }
    }

    /// Closing the core's socket initiates asynchronous XNU protocol/interface
    /// detach. Only observe its completion; never delete a shared route prefix.
    public static func waitUntilRemoved(_ identity: TunnelInterfaceIdentity?, timeout: TimeInterval = 8,
                                        snapshot: () throws -> [String: UInt32] = capture,
                                        routes: () throws -> Set<UInt32> = captureRouteInterfaceIndices,
                                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard let identity else { return } // Proxy sessions and pre-identity journals.
        guard timeout.isFinite, timeout >= 0, timeout <= 30 else {
            throw ServiceFailure("recoveryFailed", "The interface recovery timeout is invalid.")
        }
        let deadline = now() + timeout
        while true {
            let interfaces: [String: UInt32]
            let routeIndices: Set<UInt32>
            do { interfaces = try snapshot(); routeIndices = try routes() }
            catch { throw ServiceFailure("recoveryFailed", "Cannot verify tunnel removal: \(error.localizedDescription)") }
            if interfaces[identity.name] != identity.index && !routeIndices.contains(identity.index) { return }
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw ServiceFailure("recoveryFailed", "The previous tunnel interface \(identity.name) (index \(identity.index)) or its routes are still present. Recovery must finish before another session can start.")
            }
            sleep(min(0.05, remaining))
        }
    }
}
