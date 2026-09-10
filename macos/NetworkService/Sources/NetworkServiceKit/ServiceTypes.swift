import Foundation
import Darwin

public struct ServiceFailure: Error, LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public enum ServicePaths {
    public static let root = URL(fileURLWithPath: "/Library/Application Support/io.github.caocaocc.keqdroid", isDirectory: true)
    public static let application = "/Applications/KEQDIS.app"
    public static let serviceName = "io.github.caocaocc.keqdroid.network-service"
    public static let protocolVersion = 1
    public static let version = "1.0.0"
}

public struct ClientIdentity {
    public let uid: uid_t
    public let gid: gid_t
    public let connectionID: UInt64
    public init(uid: uid_t, gid: gid_t, connectionID: UInt64) { self.uid = uid; self.gid = gid; self.connectionID = connectionID }
}

public enum SecureFiles {
    public static func requireRootOwned(_ url: URL, directory: Bool? = nil) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT != S_IFLNK else {
            throw ServiceFailure("unsafeInstallation", "Unsafe ownership, permissions or symbolic link: \(url.lastPathComponent)")
        }
        if let directory, directory ? info.st_mode & S_IFMT != S_IFDIR : info.st_mode & S_IFMT != S_IFREG {
            throw ServiceFailure("unsafeInstallation", "Unexpected installation file type.")
        }
    }

    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try requireRootOwned(url.deletingLastPathComponent(), directory: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ServiceFailure("storageError", "Cannot create private service state: \(errno)") }
        var success = false
        defer { close(fd); if !success { unlink(temporary.path) } }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if result < 0 { if errno == EINTR { continue }; throw ServiceFailure("storageError", "Cannot write private service state.") }
                written += result
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ServiceFailure("storageError", "Cannot commit private service state.") }
        success = true
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }

    public static func writeJSON(_ object: Any, to url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
    }
    public static func loadJSON(_ url: URL) throws -> [String: Any] {
        try requireRootOwned(url, directory: false)
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ServiceFailure("storageError", "Invalid stored service state.") }
        return result
    }
}

public func isIPAddress(_ string: String) -> Bool {
    var address4 = in_addr(); var address6 = in6_addr()
    return string.withCString { inet_pton(AF_INET, $0, &address4) == 1 || inet_pton(AF_INET6, $0, &address6) == 1 }
}
public func isPhysicalDNSAddress(_ string: String) -> Bool {
    guard isIPAddress(string) else { return false }
    let normalized = string.lowercased()
    if normalized.contains(":") {
        var address = in6_addr()
        guard inet_pton(AF_INET6, normalized, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
        let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        let managedULA = Array(bytes.prefix(6)) == [0xfd, 0xfe, 0xdc, 0xba, 0x98, 0x76]
        return !compatible && !mapped && !linkLocal && bytes[0] != 255 && !managedULA
    }
    let bytes = normalized.split(separator: ".").compactMap { Int($0) }
    guard bytes.count == 4 else { return false }
    return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224 && !(bytes[0] == 169 && bytes[1] == 254) && !(bytes[0] == 198 && [18, 19].contains(bytes[1])) && normalized != "172.19.0.2"
}

public func jsonEqual(_ left: Any?, _ right: Any?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case (let left?, let right?): return NSDictionary(dictionary: ["v": left]).isEqual(to: ["v": right])
    default: return false
    }
}

/// A field journal records both the previous value and the exact value written.
/// Restoration only changes fields we still own; another network tool's edits win.
public struct FieldChange {
    public let before: Any?
    public let applied: Any?
    public init(before: Any?, applied: Any?) { self.before = before; self.applied = applied }
    public var dictionary: [String: Any] { ["before": before ?? NSNull(), "applied": applied ?? NSNull()] }
    public init(dictionary: [String: Any]) {
        let old = dictionary["before"], new = dictionary["applied"]
        before = old is NSNull ? nil : old; applied = new is NSNull ? nil : new
    }
}

public func restoreFields(current: [String: Any], changes: [String: FieldChange]) -> [String: Any] {
    var result = current
    for (key, change) in changes where jsonEqual(current[key], change.applied) {
        if let value = change.before { result[key] = value } else { result.removeValue(forKey: key) }
    }
    return result
}

public func restoreProtocolEnabled(current: Bool, before: Bool, fields: [String: Any], changes: [String: FieldChange]) -> Bool {
    // We always applied true. If another actor has edited even one managed
    // field, do not disable their updated protocol merely because it was off
    // before our session. An externally disabled protocol also stays disabled.
    guard current, changes.allSatisfy({ jsonEqual(fields[$0.key], $0.value.applied) }) else { return current }
    return before
}
