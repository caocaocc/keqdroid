import Foundation
import ServiceManagement

public enum LoginItem {
    public static let label = "io.github.caocaocc.keqdroid.login"
    public static let appPath = "/Applications/KEQDIS.app"

    public static func propertyList() -> [String: Any] {
        ["Label": label,
         "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath, "--args", "--login"],
         "RunAtLoad": true,
         "LimitLoadToSessionType": "Aqua",
         "AssociatedBundleIdentifiers": ["io.github.caocaocc.keqdroid"]]
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func status() -> [String: Any] {
        let exists = FileManager.default.fileExists(atPath: plistURL.path)
        var result: [String: Any] = ["enabled": exists, "requiresApproval": false]
        if #available(macOS 13, *), exists {
            let state = SMAppService.statusForLegacyPlist(at: plistURL)
            result["requiresApproval"] = state == .requiresApproval
            result["enabled"] = state == .enabled
            result["status"] = state.rawValue
        }
        return result
    }

    public static func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        if !enabled {
            _ = try run(["bootout", "\(domain)/\(label)"], allowFailure: true)
            if fm.fileExists(atPath: plistURL.path) { try fm.removeItem(at: plistURL) }
            return
        }
        guard fm.fileExists(atPath: appPath) else {
            throw DesktopError.message("Install KEQDIS in Applications before enabling login startup.")
        }
        if fm.fileExists(atPath: plistURL.path) {
            if (status()["requiresApproval"] as? Bool) == true {
                throw DesktopError.message("Allow KEQDIS in System Settings → Login Items first.")
            }
            return
        }
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList(), format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        do { _ = try run(["bootstrap", domain, plistURL.path]) }
        catch { try? fm.removeItem(at: plistURL); throw error }
    }

    private static func run(_ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let error = Pipe()
        process.standardError = error
        try process.run()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else {
            throw DesktopError.message("Login startup could not be changed: \(String(decoding: errorData, as: UTF8.self))")
        }
        return process.terminationStatus
    }
}

public enum DesktopError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
