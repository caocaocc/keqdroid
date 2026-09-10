import XCTest
import dnssd
@testable import NetworkServiceKit

final class SystemDNSReadinessTests: XCTestCase {
    func testNegativeProbeNeedsPositiveFallbackWithinSharedDeadline() throws {
        var time: TimeInterval = 0
        var names: [String] = []
        var limits: [TimeInterval] = []
        try SystemDNSReadiness.verify(now: { time }, query: { name, limit in
            names.append(name); limits.append(limit); time += 2
            return names.count == 1 ? .negative : .positive
        })
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names[0].hasSuffix(".example.com."))
        XCTAssertEqual(names[1], "example.com.")
        XCTAssertEqual(limits, [5, 3])
    }
    func testNegativeFallbackErrorsAndExpiredBudgetFail() {
        XCTAssertThrowsError(try SystemDNSReadiness.verify(query: { _, _ in .negative }))
        XCTAssertThrowsError(try SystemDNSReadiness.verify(query: { _, _ in throw ServiceFailure("synthetic", "SERVFAIL") }))
        var time: TimeInterval = 0
        var calls = 0
        XCTAssertThrowsError(try SystemDNSReadiness.verify(now: { time }, query: { _, _ in calls += 1; time = 5; return .negative }))
        XCTAssertEqual(calls, 1)
    }
    func testDNSCallbackRejectsFailuresAndMalformedPositiveRecords() throws {
        XCTAssertEqual(try SystemDNSReadiness.interpret(error: Int32(kDNSServiceErr_NoSuchRecord), added: false, type: 0, recordClass: 0, length: 0), .negative)
        XCTAssertEqual(try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 4), .positive)
        XCTAssertThrowsError(try SystemDNSReadiness.interpret(error: Int32(kDNSServiceErr_Timeout), added: false, type: 0, recordClass: 0, length: 0))
        XCTAssertThrowsError(try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 0))
        XCTAssertNil(try SystemDNSReadiness.interpret(error: 0, added: false, type: 1, recordClass: 1, length: 4))
    }
}
