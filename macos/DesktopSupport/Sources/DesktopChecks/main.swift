import Foundation
import AppKit
import KEQDesktopSupport

var count = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    count += 1
}
check(HotkeyCombination(token: "meta+keyA")?.keyCode == 0, "Command A physical key")
check(HotkeyCombination(token: "ctrl+alt+keyT")?.keyCode == 17, "multiple modifiers")
check(HotkeyCombination(token: "keyA") == nil, "bare letters rejected")
check(HotkeyCombination(token: "unknown+keyA") == nil, "unknown modifier rejected")
check(HotkeyCombination(token: "meta+notAKey") == nil, "unknown key rejected")
check(HotkeyCombination(token: "f12") != nil, "function key allowed")
let login = LoginItem.propertyList()
check(login["KeepAlive"] == nil, "login has no KeepAlive")
check(login["RunAtLoad"] as? Bool == true, "login runs at load")
check(login["LimitLoadToSessionType"] as? String == "Aqua", "login is user GUI session")
check(login["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", "/Applications/KEQDIS.app", "--args", "--login"], "explicit login launch marker")

// Real bundle metadata fixtures; no application launch or global hotkey registration.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("keqdis-catalog-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
func bundle(_ path: URL, executable: String, identifier: String) throws -> URL {
    let content = path.appendingPathComponent("Contents")
    try fm.createDirectory(at: content.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
        "CFBundlePackageType": "APPL", "CFBundleName": "Test Browser", "CFBundleExecutable": executable], format: .xml, options: 0)
    try data.write(to: content.appendingPathComponent("Info.plist"))
    let file = content.appendingPathComponent("MacOS/\(executable)")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
}
let app = root.appendingPathComponent("Browser.app")
let main = try bundle(app, executable: "Browser", identifier: "test.browser")
let nested = try bundle(app.appendingPathComponent("Contents/Frameworks/Browser Helper.app"), executable: "Helper", identifier: "test.browser.helper")
let xpc = try bundle(app.appendingPathComponent("Contents/XPCServices/Network.xpc"), executable: "Network", identifier: "test.browser.xpc")
let entry = ApplicationCatalog.entry(at: app, runningPaths: [nested.path])
check(entry?["bundleId"] as? String == "test.browser", "bundle id kept separate")
check(entry?["isRunning"] as? Bool == true, "nested running process recognized")
let paths = Set(entry?["executablePaths"] as? [String] ?? [])
check(paths == Set([main.path, nested.path, xpc.path]), "main, Helper and XPC expanded exactly")
let outside = try bundle(root.appendingPathComponent("Outside.app"), executable: "Outside", identifier: "test.outside")
try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/Escape"), withDestinationURL: outside)
let afterLink = ApplicationCatalog.entry(at: app)?["executablePaths"] as? [String] ?? []
check(!afterLink.contains(outside.path), "bundle escape symlink excluded")
check(ApplicationCatalog.entry(at: root.appendingPathComponent("Missing.app")) == nil, "missing bundle rejected")

func statusArguments(_ status: String, speed: Bool = true) -> [String: Any] {
    ["status": status, "statusText": "已连接", "showSpeed": speed,
     "uploadText": "12 MB/s", "downloadText": "— KB/s", "uploadLabel": "上传", "downloadLabel": "下载"]
}
var statePixels: [StatusItemPresentation.Status: Data] = [:]
for status in StatusItemPresentation.Status.allCases {
    let presentation = try StatusItemPresentation(arguments: statusArguments(status.rawValue))
    check(presentation.status == status, "menu bar accepts \(status.rawValue)")
    check(presentation.accessibilityText == "KEQDIS — 已连接\n上传: 12 MB/s\n下载: — KB/s", "localized accessible rates")
    for speed in [false, true] {
        let value = try StatusItemPresentation(arguments: statusArguments(status.rawValue, speed: speed))
        let image = StatusItemRenderer.image(for: value)
        check(image.isTemplate, "menu bar uses template rendering")
        check(image.size == NSSize(width: speed ? 87 : 18, height: 18), "fixed menu bar image dimensions")
        check(image.accessibilityDescription == value.accessibilityText, "image includes accessible status")
        if !speed {
            check(value.accessibilityText == "KEQDIS — 已连接", "icon-only accessibility omits rates")
            statePixels[status] = image.tiffRepresentation
        }
    }
}
check(statePixels.count == StatusItemPresentation.Status.allCases.count &&
    statePixels.values.allSatisfy { !$0.isEmpty }, "status markers rasterize")
check(statePixels[.disconnected] != statePixels[.connected], "connected disc differs from hollow center")
check(statePixels[.connected] != statePixels[.connecting], "transient dots differ from connected disc")
check(statePixels[.connecting] == statePixels[.disconnecting], "both transient states use static dots")
check(statePixels[.connecting] != statePixels[.error], "error marker differs from transient dots")
let rateAttributes: [NSAttributedString.Key: Any] = [.font: StatusItemRenderer.rateFont]
let unitAttributes: [NSAttributedString.Key: Any] = [.font: StatusItemRenderer.rateUnitFont]
for text in ["— KB/s", "0 KB/s", "1023 KB/s", "9999 MB/s", ">9999 MB/s"] {
    let columns = StatusItemRenderer.rateColumns(text)
    let numberWidth = (columns.number as NSString).size(withAttributes: rateAttributes).width
    let unitWidth = (columns.unit as NSString).size(withAttributes: unitAttributes).width
    check(numberWidth <= StatusItemRenderer.rateNumberWidth && unitWidth <= StatusItemRenderer.rateUnitWidth,
        "maximum formatted rate fits its columns: \(text)")
    check(abs(columns.numberX + numberWidth - 61) < 0.001, "rate numeric values are right-aligned")
    check(columns.unitX == 63, "rate unit begins at a fixed position")
    check("\(columns.number) \(columns.unit)" == text, "rate split preserves value and unit")
}
check(("K" as NSString).size(withAttributes: unitAttributes).width ==
    ("M" as NSString).size(withAttributes: unitAttributes).width, "KB and MB suffixes align")
let malformed: [(String, Any)] = [("status", "running"), ("showSpeed", 1),
    ("statusText", ""), ("statusText", String(repeating: "x", count: 161)),
    ("uploadText", "1\nMB/s"), ("downloadText", String(repeating: "9", count: 13)),
    ("uploadLabel", false), ("downloadLabel", String(repeating: "x", count: 33))]
for (key, value) in malformed {
    var input = statusArguments("connected")
    input[key] = value
    check((try? StatusItemPresentation(arguments: input)) == nil, "malformed \(key) rejected")
}

let serverLeaf: [String: Any] = ["title": "节点", "id": "server-1", "checked": true]
let menuArguments: [String: Any] = ["statusText": "已连接", "toggleText": "断开", "toggleEnabled": true, "toggleConnects": false,
    "mode": "proxy", "modeEnabled": true, "proxyText": "Proxy", "tunText": "TUN",
    "serversTitle": "节点", "serversEnabled": true, "servers": [["title": "订阅", "children": [serverLeaf]]],
    "openText": "打开应用", "quitText": "退出"]
let menu = try StatusMenuPresentation(arguments: menuArguments)
check(menu.servers == [.group(title: "订阅", children: [.leaf(title: "节点", id: "server-1", checked: true)])], "native menu preserves groups and selection")
check(menu.allows(.toggleConnection(false)), "enabled menu can disconnect with the displayed intent")
check(!menu.allows(.toggleConnection(true)), "old connect item cannot become disconnect")
var changedToggle = menuArguments
changedToggle["toggleText"] = "连接"
changedToggle["toggleConnects"] = true
let latestToggle = try StatusMenuPresentation(arguments: changedToggle)
check(!latestToggle.allows(.toggleConnection(false)), "old disconnect item cannot become connect")
check(latestToggle.allows(.toggleConnection(true)), "current connect intent is accepted")
check(menu.allows(.setMode("tun")), "enabled menu can switch mode")
check(!menu.allows(.setMode("proxy")) && !menu.allows(.setMode("other")), "menu ignores current and unknown mode")
check(menu.allows(.selectServer("server-1")) && !menu.allows(.selectServer("removed")), "menu rejects stale node")
check(StatusMenuPresentation.Action.selectServer("server-1").arguments == ["action": "selectServer", "value": "server-1"], "node action contains stable id only")
check(StatusMenuPresentation.Action.setMode("tun").arguments == ["action": "setMode", "value": "tun"], "mode action is fixed")
check(StatusMenuPresentation.Action.toggleConnection(false).arguments == ["action": "toggleConnection", "value": "disconnect"], "disconnect action carries its original intent")
check(StatusMenuPresentation.Action.toggleConnection(true).arguments == ["action": "toggleConnection", "value": "connect"], "connect action carries its original intent")
var disabledMenu = menuArguments
for field in ["toggleEnabled", "modeEnabled", "serversEnabled"] { disabledMenu[field] = false }
let disabled = try StatusMenuPresentation(arguments: disabledMenu)
check(!disabled.allows(.toggleConnection(false)) && !disabled.allows(.setMode("tun")) && !disabled.allows(.selectServer("server-1")), "latest snapshot blocks old enabled actions")
for (field, value): (String, Any) in [("mode", "auto"), ("toggleEnabled", 1), ("toggleConnects", 1), ("openText", "Open\nApp"),
    ("servers", [["title": "Bad", "id": "node", "checked": 1]]),
    ("servers", [["title": "Bad", "children": [], "id": "mixed"]])] {
    var input = menuArguments
    input[field] = value
    check((try? StatusMenuPresentation(arguments: input)) == nil, "malformed menu \(field) rejected atomically")
}
var nestedMenu = serverLeaf
for _ in 0..<7 { nestedMenu = ["title": "Group", "children": [nestedMenu]] }
var treeMenu = menuArguments
treeMenu["servers"] = [nestedMenu]
check((try? StatusMenuPresentation(arguments: treeMenu)) != nil, "eight-level menu accepted")
nestedMenu = ["title": "Group", "children": [nestedMenu]]
treeMenu["servers"] = [nestedMenu]
check((try? StatusMenuPresentation(arguments: treeMenu)) == nil, "deep menu rejected")
treeMenu["servers"] = Array(repeating: serverLeaf, count: 12000)
check((try? StatusMenuPresentation(arguments: treeMenu)) != nil, "menu node budget accepts boundary")
treeMenu["servers"] = [["title": "Group", "children": Array(repeating: serverLeaf, count: 12000)]]
check((try? StatusMenuPresentation(arguments: treeMenu)) == nil, "menu node budget includes group nodes")
let unicodeTitle = "اشتراک‌ها 👩‍💻"
var unicodeStatus = statusArguments("connected")
unicodeStatus["statusText"] = unicodeTitle
check((try? StatusItemPresentation(arguments: unicodeStatus))?.statusText == unicodeTitle, "status preserves Persian ZWNJ and emoji ZWJ")
var unicodeMenu = menuArguments
unicodeMenu["servers"] = [["title": unicodeTitle, "id": "server-1", "checked": true]]
check((try? StatusMenuPresentation(arguments: unicodeMenu))?.servers == [.leaf(title: unicodeTitle, id: "server-1", checked: true)], "menu preserves Persian and joined emoji")
for scalar in ["\u{0000}", "\u{0085}", "\u{2028}", "\u{2029}"] {
    unicodeStatus["statusText"] = "before\(scalar)after"
    unicodeMenu["serversTitle"] = "before\(scalar)after"
    check((try? StatusItemPresentation(arguments: unicodeStatus)) == nil, "status rejects controls and separators")
    check((try? StatusMenuPresentation(arguments: unicodeMenu)) == nil, "menu rejects controls and separators")
}
check(!menu.serversOverflow, "overflow defaults off")
var overflowMenu = menuArguments
overflowMenu["servers"] = []
overflowMenu["serversEnabled"] = false
overflowMenu["serversOverflow"] = true
let overflow = try StatusMenuPresentation(arguments: overflowMenu)
check(overflow.serversOverflow && overflow.servers.isEmpty, "overflow selects a window-only fallback")
check(!overflow.allows(.selectServer("server-1")), "overflow cannot emit a server action")
overflowMenu["servers"] = [serverLeaf]
check((try? StatusMenuPresentation(arguments: overflowMenu)) == nil, "overflow rejects a nonempty server tree")
overflowMenu["servers"] = []
overflowMenu["serversOverflow"] = 1
check((try? StatusMenuPresentation(arguments: overflowMenu)) == nil, "overflow requires an actual bool")
print("\(count) desktop checks passed")
