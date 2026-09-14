import XCTest
@testable import KEQDesktopSupport

final class DesktopSupportTests: XCTestCase {
    func testHotkeyUsesPhysicalMacKeyAndRejectsBareLetters() {
        XCTAssertEqual(HotkeyCombination(token: "meta+keyA")?.keyCode, 0)
        XCTAssertEqual(HotkeyCombination(token: "ctrl+alt+keyT")?.keyCode, 17)
        XCTAssertNil(HotkeyCombination(token: "keyA"))
        XCTAssertNil(HotkeyCombination(token: "unknown+keyA"))
        XCTAssertNil(HotkeyCombination(token: "meta+notAKey"))
        XCTAssertNotNil(HotkeyCombination(token: "f12"))
    }

    func testLoginItemRunsOnceInUserSessionWithExplicitLaunchMarker() {
        let plist = LoginItem.propertyList()
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["KeepAlive"])
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-g", "-a", "/Applications/KEQDIS.app", "--args", "--login"])
    }
}
