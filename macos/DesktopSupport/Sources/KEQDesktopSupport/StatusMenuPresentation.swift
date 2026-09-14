import Foundation
import CoreFoundation

/// A bounded menu snapshot. Native clicks are checked against the latest snapshot,
/// even when AppKit is still displaying an older, open menu.
public struct StatusMenuPresentation: Equatable {
    public indirect enum Server: Equatable {
        case group(title: String, children: [Server])
        case leaf(title: String, id: String, checked: Bool)
    }

    public enum Action: Equatable {
        case toggleConnection(Bool)
        case setMode(String)
        case selectServer(String)

        public var arguments: [String: String] {
            switch self {
            case .toggleConnection(let connects):
                return ["action": "toggleConnection", "value": connects ? "connect" : "disconnect"]
            case .setMode(let mode): return ["action": "setMode", "value": mode]
            case .selectServer(let id): return ["action": "selectServer", "value": id]
            }
        }
    }

    public let statusText: String
    public let toggleText: String
    public let toggleEnabled: Bool
    public let toggleConnects: Bool
    public let mode: String
    public let modeEnabled: Bool
    public let proxyText: String
    public let tunText: String
    public let serversTitle: String
    public let serversEnabled: Bool
    public let serversOverflow: Bool
    public let servers: [Server]
    public let openText: String
    public let quitText: String
    private let serverIDs: Set<String>

    public init(arguments: [String: Any]) throws {
        statusText = try Self.text(arguments, "statusText")
        toggleText = try Self.text(arguments, "toggleText")
        toggleEnabled = try Self.boolean(arguments, "toggleEnabled")
        toggleConnects = try Self.boolean(arguments, "toggleConnects")
        mode = try Self.text(arguments, "mode")
        guard ["proxy", "tun"].contains(mode) else { throw Self.invalid("mode") }
        modeEnabled = try Self.boolean(arguments, "modeEnabled")
        proxyText = try Self.text(arguments, "proxyText")
        tunText = try Self.text(arguments, "tunText")
        serversTitle = try Self.text(arguments, "serversTitle")
        serversEnabled = try Self.boolean(arguments, "serversEnabled")
        serversOverflow = arguments["serversOverflow"] == nil
            ? false : try Self.boolean(arguments, "serversOverflow")
        openText = try Self.text(arguments, "openText")
        quitText = try Self.text(arguments, "quitText")
        var count = 0
        var ids: Set<String> = []
        servers = try Self.parseServers(arguments["servers"], depth: 1, count: &count, ids: &ids)
        guard !serversOverflow || servers.isEmpty else { throw Self.invalid("serversOverflow") }
        serverIDs = ids
    }

    public func allows(_ action: Action) -> Bool {
        switch action {
        case .toggleConnection(let connects):
            return toggleEnabled && connects == toggleConnects
        case .setMode(let requested):
            return modeEnabled && ["proxy", "tun"].contains(requested) && requested != mode
        case .selectServer(let id): return serversEnabled && serverIDs.contains(id)
        }
    }

    private static func parseServers(_ value: Any?, depth: Int, count: inout Int,
                                     ids: inout Set<String>) throws -> [Server] {
        guard let nodes = value as? [[String: Any]], depth <= 8,
              nodes.count <= 12000 - count else { throw invalid("servers") }
        var result: [Server] = []
        for node in nodes {
            count += 1
            guard count <= 12000 else { throw invalid("servers") }
            let title = try text(node, "title")
            if node["children"] != nil {
                guard Set(node.keys) == Set(["title", "children"]) else { throw invalid("server group") }
                let children = try parseServers(node["children"], depth: depth + 1, count: &count, ids: &ids)
                result.append(.group(title: title, children: children))
            } else {
                guard Set(node.keys) == Set(["title", "id", "checked"]) else { throw invalid("server") }
                let id = try text(node, "id", limit: 256)
                let checked = try boolean(node, "checked")
                ids.insert(id)
                result.append(.leaf(title: title, id: id, checked: checked))
            }
        }
        return result
    }

    private static func text(_ arguments: [String: Any], _ key: String, limit: Int = 160) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty,
              value.utf8.count <= limit * 4, value.count <= limit,
              value.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) &&
                  $0.value != 0x2028 && $0.value != 0x2029
              }) else { throw invalid(key) }
        return value
    }

    private static func boolean(_ arguments: [String: Any], _ key: String) throws -> Bool {
        guard let value = arguments[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw invalid(key) }
        return value.boolValue
    }

    private static func invalid(_ field: String) -> DesktopError {
        .message("Invalid menu bar menu: \(field)")
    }
}
