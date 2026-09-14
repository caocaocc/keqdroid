import XCTest
@testable import NetworkServiceKit

final class AutoSelectLogTests: XCTestCase {
    func testFailureIsCountedBeforeDisplayFilterAcrossChunks() {
        var log = CoreSessionLog(xrayThreshold: 2)
        for byte in "[Info] splithttp: failed to dial 本地\n".utf8 { log.append(Data([byte])) }
        XCTAssertEqual(log.dialFailures, 1)
        XCTAssertTrue(log.data.isEmpty)
        log.append(Data("[Warning] visible\n".utf8))
        XCTAssertEqual(String(decoding: log.data, as: UTF8.self), "[Warning] visible\n")
        log.finish(); log.finish()
        XCTAssertEqual(log.dialFailures, 1)
    }

    func testDirectBlockedAndUDPFailuresDoNotWakeWatchdog() {
        for line in ["[TCP] dial DIRECT error: refused", "[TCP] dial REJECT error: refused", "[UDP] dial proxy error: refused", "open connection to example using outbound/direct[direct]: refused"] {
            XCTAssertFalse(CoreSessionLog.isDialFailure(line))
        }
    }
}
