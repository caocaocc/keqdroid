import Foundation
import Darwin

public enum CoreOutputReader {
    @discardableResult
    public static func drain(_ descriptor: Int32, maximumReads: Int = .max, consume: (Data) -> Void) -> Int {
        guard descriptor >= 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var total = 0
        var reads = 0
        while reads < maximumReads {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            reads += 1
            total += count
            consume(Data(buffer.prefix(count)))
        }
        return total
    }
}
