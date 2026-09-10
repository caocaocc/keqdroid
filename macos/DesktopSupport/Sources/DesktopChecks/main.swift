import Foundation
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
print("\(count) desktop checks passed")
