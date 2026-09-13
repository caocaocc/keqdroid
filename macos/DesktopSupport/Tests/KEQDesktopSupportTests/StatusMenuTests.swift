import XCTest
@testable import KEQDesktopSupport

final class StatusMenuTests: XCTestCase {
    private var leaf: [String: Any] { ["title": "节点", "id": "server-1", "checked": true] }

    private func arguments(servers: [[String: Any]]? = nil) -> [String: Any] {
        ["statusText": "已连接", "toggleText": "断开", "toggleEnabled": true, "toggleConnects": false,
         "mode": "proxy", "modeEnabled": true, "proxyText": "Proxy", "tunText": "TUN",
         "serversTitle": "节点", "serversEnabled": true,
         "servers": servers ?? [["title": "订阅", "children": [leaf]]],
         "openText": "打开应用", "quitText": "退出"]
    }

    func testGroupedServersKeepCheckedStateAndFixedActionMetadata() throws {
        let menu = try StatusMenuPresentation(arguments: arguments())
        XCTAssertEqual(menu.servers, [.group(title: "订阅", children: [
            .leaf(title: "节点", id: "server-1", checked: true),
        ])])
        XCTAssertTrue(menu.allows(.toggleConnection(false)))
        XCTAssertTrue(menu.allows(.setMode("tun")))
        XCTAssertFalse(menu.allows(.setMode("proxy")))
        XCTAssertFalse(menu.allows(.setMode("invalid")))
        XCTAssertTrue(menu.allows(.selectServer("server-1")))
        XCTAssertFalse(menu.allows(.selectServer("removed")))
        XCTAssertEqual(StatusMenuPresentation.Action.selectServer("server-1").arguments,
            ["action": "selectServer", "value": "server-1"])
        XCTAssertEqual(StatusMenuPresentation.Action.toggleConnection(false).arguments,
            ["action": "toggleConnection", "value": "disconnect"])
        XCTAssertEqual(StatusMenuPresentation.Action.toggleConnection(true).arguments,
            ["action": "toggleConnection", "value": "connect"])
        XCTAssertEqual(StatusMenuPresentation.Action.setMode("tun").arguments,
            ["action": "setMode", "value": "tun"])
    }

    func testLatestDisabledSnapshotRejectsActionsFromAnOlderOpenMenu() throws {
        var input = arguments()
        input["toggleEnabled"] = false
        input["modeEnabled"] = false
        input["serversEnabled"] = false
        let menu = try StatusMenuPresentation(arguments: input)
        XCTAssertFalse(menu.allows(.toggleConnection(false)))
        XCTAssertFalse(menu.allows(.setMode("tun")))
        XCTAssertFalse(menu.allows(.selectServer("server-1")))
        let empty = try StatusMenuPresentation(arguments: arguments(servers: []))
        XCTAssertEqual(empty.servers, [])
        XCTAssertFalse(empty.allows(.selectServer("server-1")))
    }

    func testAnOldDisconnectItemCannotBecomeAConnectAction() throws {
        var input = arguments()
        input["toggleText"] = "连接"
        input["toggleConnects"] = true
        let latest = try StatusMenuPresentation(arguments: input)
        XCTAssertTrue(latest.allows(.toggleConnection(true)))
        XCTAssertFalse(latest.allows(.toggleConnection(false)))
        input["toggleText"] = "Connect"
        let translated = try StatusMenuPresentation(arguments: input)
        XCTAssertTrue(translated.allows(.toggleConnection(true)))
        XCTAssertFalse(translated.allows(.toggleConnection(false)))
    }

    func testMalformedTreesAndScalarsAreRejectedAtomically() {
        let mutations: [(String, Any)] = [
            ("mode", "auto"), ("toggleEnabled", 1), ("toggleConnects", 1), ("serversEnabled", "true"),
            ("statusText", ""), ("openText", "Open\nApp"),
            ("quitText", String(repeating: "x", count: 161)),
            ("servers", [["title": "Bad", "id": "server-1", "checked": 1]]),
            ("servers", [["title": "Bad", "id": "", "checked": false]]),
            ("servers", [["title": "Bad", "id": String(repeating: "x", count: 257), "checked": false]]),
            ("servers", [["title": "Bad", "children": "not a list"]]),
            ("servers", [["title": "Bad", "children": [], "id": "unexpected"]]),
            ("servers", [["title": "Bad", "id": "server-1"]]),
            ("servers", ["not a dictionary"]),
        ]
        for (key, value) in mutations {
            var input = arguments()
            input[key] = value
            XCTAssertThrowsError(try StatusMenuPresentation(arguments: input), key)
        }
        for key in arguments().keys {
            var input = arguments()
            input.removeValue(forKey: key)
            XCTAssertThrowsError(try StatusMenuPresentation(arguments: input), key)
        }
    }

    func testNodeAndDepthBudgetsCountGroupsAndLeavesTogether() throws {
        XCTAssertNoThrow(try StatusMenuPresentation(arguments: arguments(servers: Array(repeating: leaf, count: 12000))))
        XCTAssertThrowsError(try StatusMenuPresentation(arguments: arguments(servers: Array(repeating: leaf, count: 12001))))
        var nested = leaf
        for _ in 0..<7 { nested = ["title": "Group", "children": [nested]] }
        XCTAssertNoThrow(try StatusMenuPresentation(arguments: arguments(servers: [nested])))
        nested = ["title": "Group", "children": [nested]]
        XCTAssertThrowsError(try StatusMenuPresentation(arguments: arguments(servers: [nested])))
        let full: [String: Any] = ["title": "Group", "children": Array(repeating: leaf, count: 12000)]
        XCTAssertThrowsError(try StatusMenuPresentation(arguments: arguments(servers: [full])))
    }

    func testPersianAndEmojiTitlesArePreserved() throws {
        let title = "اشتراک‌ها 👩‍💻"
        let menu = try StatusMenuPresentation(arguments: arguments(servers: [
            ["title": title, "id": "server-1", "checked": true],
        ]))
        XCTAssertEqual(menu.servers, [.leaf(title: title, id: "server-1", checked: true)])
    }

    func testOverflowIsOptionalAndOnlyAcceptsAnEmptyServerTree() throws {
        let original = try StatusMenuPresentation(arguments: arguments())
        XCTAssertFalse(original.serversOverflow)
        var input = arguments(servers: [])
        input["serversOverflow"] = true
        input["serversEnabled"] = false
        let fallback = try StatusMenuPresentation(arguments: input)
        XCTAssertTrue(fallback.serversOverflow)
        XCTAssertEqual(fallback.servers, [])
        XCTAssertFalse(fallback.allows(.selectServer("server-1")))
        input["servers"] = [leaf]
        XCTAssertThrowsError(try StatusMenuPresentation(arguments: input))
        input["servers"] = []
        input["serversOverflow"] = 1
        XCTAssertThrowsError(try StatusMenuPresentation(arguments: input))
    }
}
