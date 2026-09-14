import XCTest
import dnssd
import Darwin
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
    func testPublicLocalOnlyQueryNeedsIntermediateFlagsForNegativeAnswer() throws {
        let absentName = "keqdis-local-check-\(UUID().uuidString.lowercased()).invalid."
        XCTAssertThrowsError(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 0.25, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), flags: DNSServiceFlags(kDNSServiceFlagsTimeout))) { error in
            XCTAssertEqual((error as? ServiceFailure)?.code, "systemDNSUnavailable")
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertEqual(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly)), .negative)
    }
    func testIntermediateCNAMEWaitsForPositiveARecord() throws {
        XCTAssertNil(try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 1, length: 13))
        XCTAssertEqual(try SystemDNSReadiness.interpret(error: 0, added: true, type: 1, recordClass: 1, length: 4), .positive)
        XCTAssertThrowsError(try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 1, length: 0))
        XCTAssertThrowsError(try SystemDNSReadiness.interpret(error: 0, added: true, type: UInt16(kDNSServiceType_CNAME), recordClass: 3, length: 13))
    }
    func testQueryFailureNamesInitialOrFallbackPhaseWithoutChangingCode() {
        for fallback in [false, true] {
            var count = 0
            XCTAssertThrowsError(try SystemDNSReadiness.verify(query: { _, _ in
                count += 1
                if fallback && count == 1 { return .negative }
                throw ServiceFailure("systemDNSUnavailable", "System DNS resolution timed out.")
            })) { error in
                XCTAssertEqual((error as? ServiceFailure)?.code, "systemDNSUnavailable")
                XCTAssertTrue(error.localizedDescription.contains(fallback ? "positive fallback" : "initial randomized probe"))
            }
        }
    }
    func testPendingLocalOnlyQueryValidatesOnCallerAndCancelsWithOriginalFailure() throws {
        let absentName = "keqdis-local-progress-\(UUID().uuidString.lowercased()).invalid."
        let caller = pthread_self()
        for failureCode in ["coreExited", "tunnelInterfaceLost"] {
            var calls = 0
            var onCaller = true
            XCTAssertThrowsError(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), flags: DNSServiceFlags(kDNSServiceFlagsTimeout), progress: {
                calls += 1
                onCaller = onCaller && pthread_equal(pthread_self(), caller) != 0
                if calls == 3 { throw ServiceFailure(failureCode, "Synthetic startup health failure.", stage: "systemDNS") }
            })) { error in
                XCTAssertEqual((error as? ServiceFailure)?.code, failureCode)
                XCTAssertEqual((error as? ServiceFailure)?.stage, "systemDNS")
            }
            XCTAssertEqual(calls, 3)
            XCTAssertTrue(onCaller)
            XCTAssertEqual(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly)), .negative)
            XCTAssertEqual(calls, 3)
        }
    }
    func testCompletedLocalOnlyQueryStillValidatesHealth() throws {
        let absentName = "keqdis-local-progress-\(UUID().uuidString.lowercased()).invalid."
        var calls = 0
        XCTAssertEqual(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 3, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), progress: { calls += 1 }), .negative)
        XCTAssertGreaterThanOrEqual(calls, 2)
    }
    func testProgressConsumesExistingDeadline() {
        let absentName = "keqdis-local-progress-\(UUID().uuidString.lowercased()).invalid."
        var calls = 0
        XCTAssertThrowsError(try SystemDNSReadiness.queryRecord(name: absentName, timeout: 0.01, interfaceIndex: UInt32(kDNSServiceInterfaceIndexLocalOnly), progress: {
            calls += 1
            Thread.sleep(forTimeInterval: 0.03)
        })) { error in
            XCTAssertEqual((error as? ServiceFailure)?.code, "systemDNSUnavailable")
        }
        XCTAssertEqual(calls, 1)
    }
}
