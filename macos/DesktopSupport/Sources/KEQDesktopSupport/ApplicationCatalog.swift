import AppKit

public enum ApplicationCatalog {
    public static func entry(at bundleURL: URL, runningPaths: Set<String> = []) -> [String: Any]? {
        let canonical = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: canonical), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        var paths = Set([executable.resolvingSymlinksInPath().path])
        let content = canonical.appendingPathComponent("Contents")
        // Helpers and XPC services carry the network sockets for browsers and Electron apps.
        if let enumerator = FileManager.default.enumerator(at: content,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(content.path + "/") else { continue }
                if ["app", "xpc"].contains(url.pathExtension),
                   let nested = Bundle(url: url)?.executableURL,
                   nested.resolvingSymlinksInPath().path.hasPrefix(content.path + "/") {
                    paths.insert(nested.resolvingSymlinksInPath().path)
                } else if url.deletingLastPathComponent().lastPathComponent == "MacOS",
                          FileManager.default.isExecutableFile(atPath: url.path),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    paths.insert(resolved.path)
                }
            }
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? canonical.deletingPathExtension().lastPathComponent
        var result: [String: Any] = ["packageName": executable.path, "appName": name,
            "isRunning": !paths.isDisjoint(with: runningPaths),
            "isSystem": canonical.path.hasPrefix("/System/"), "installPath": executable.path,
            "bundlePath": canonical.path, "executablePaths": paths.sorted()]
        if let identifier = bundle.bundleIdentifier { result["bundleId"] = identifier }
        return result
    }

    public static func list(includeSystem: Bool) -> [[String: Any]] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.path })
        var roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        if includeSystem { roots.append(URL(fileURLWithPath: "/System/Applications")) }
        var entries: [String: [String: Any]] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                enumerator.skipDescendants()
                if let entry = entry(at: url, runningPaths: running), let path = entry["bundlePath"] as? String {
                    entries[path] = entry
                }
            }
        }
        return entries.values.sorted {
            ($0["appName"] as? String ?? "").localizedStandardCompare($1["appName"] as? String ?? "") == .orderedAscending
        }
    }

    public static func icon(path: String) -> String? {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 48, height: 48)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
