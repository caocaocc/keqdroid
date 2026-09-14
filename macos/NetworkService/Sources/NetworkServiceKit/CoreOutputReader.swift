import Foundation
import Darwin

public enum CoreOutputReader {
    @discardableResult
    public static func drain(_ descriptor: Int32, maximumReads: Int = .max, onEOF: (() -> Void)? = nil, consume: (Data) -> Void) -> Int {
        guard descriptor >= 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var total = 0
        var reads = 0
        while reads < maximumReads {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { onEOF?(); break }
            if count < 0 { break }
            reads += 1
            total += count
            consume(Data(buffer.prefix(count)))
        }
        return total
    }
}

/// Session output only. Count complete lines before applying the user's Xray
/// display level; snapshots must not recount a rolling log on every poll.
public struct CoreSessionLog {
    public private(set) var data = Data()
    public private(set) var dialFailures = 0
    private var pending = [UInt8]()
    private let threshold: Int
    private static let limit = 64 * 1024

    public init(xrayThreshold: Int = 0) { threshold = xrayThreshold }

    public mutating func append(_ bytes: Data) {
        for byte in bytes {
            if byte == 10 { completeLine() }
            else if pending.count < Self.limit { pending.append(byte) }
        }
    }

    public mutating func finish() {
        if !pending.isEmpty { completeLine() }
    }

    private mutating func completeLine() {
        if pending.last == 13 { pending.removeLast() }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        if Self.isDialFailure(line), dialFailures < Int.max { dialFailures += 1 }
        guard Self.xrayLevel(line) >= threshold else { return }
        data.append(contentsOf: line.utf8)
        data.append(10)
        if data.count > Self.limit { data.removeFirst(data.count - Self.limit) }
    }

    // Keep these patterns aligned with lib/services/core_dial_failures.dart.
    public static func isDialFailure(_ line: String) -> Bool {
        if line.contains("failed to find an available destination") { return true }
        if let range = line.range(of: "splithttp: ") {
            let what = line[range.upperBound...]
            if what.hasPrefix("failed to create") { return false }
            return what.hasPrefix("failed to ") || what.hasPrefix("unexpected status ")
        }
        if let range = line.range(of: "[TCP] dial ") {
            guard line.contains(" error: ") else { return false }
            let target = line[range.upperBound...]
            return !target.hasPrefix("DIRECT") && !target.hasPrefix("REJECT")
        }
        if line.contains("open connection to ") && line.contains(" using outbound/") {
            return !line.contains("outbound/direct[") && !line.contains("outbound/block[")
        }
        return false
    }

    private static func xrayLevel(_ line: String) -> Int {
        guard let tag = line.firstIndex(of: "[") else { return 4 }
        let rest = line[tag...]
        for (level, label) in ["[Debug]", "[Info]", "[Warning]", "[Error]"].enumerated() {
            if rest.hasPrefix(label) { return level }
        }
        return 4 // Other cores, access logs and banners keep their own levels.
    }
}
