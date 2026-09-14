import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  func testApplicationIdentityAndURLSchemes() throws {
    let host = try XCTUnwrap(Bundle(identifier: "io.github.caocaocc.keqdroid"))
    XCTAssertEqual(host.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "12.0")
    let types = try XCTUnwrap(host.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    XCTAssertEqual(Set(schemes), Set(["keqdroid", "keqdis"]))
  }

}
