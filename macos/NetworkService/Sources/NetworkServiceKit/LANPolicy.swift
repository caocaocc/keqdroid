import Foundation

/// Explicit session opt-in. Never infer LAN permission from arbitrary core JSON.
public struct LANConfiguration {
    public let socksPort: Int
    public let httpPort: Int
    public let username: String
    public let password: String
    public var ports: Set<Int> { [socksPort, httpPort] }
    public var authenticated: Bool { !username.isEmpty }

    public init(arguments: Any, reservedPorts: Set<Int>) throws {
        guard let value = arguments as? [String: Any],
              Set(value.keys) == Set(["socksPort", "httpPort", "username", "password"]),
              let socks = value["socksPort"] as? Int, let http = value["httpPort"] as? Int,
              (1024...65535).contains(socks), (1024...65535).contains(http),
              socks != http, !reservedPorts.contains(socks), !reservedPorts.contains(http),
              let user = value["username"] as? String, let pass = value["password"] as? String,
              user.isEmpty == pass.isEmpty,
              user == user.trimmingCharacters(in: .whitespacesAndNewlines), !user.contains(":"),
              [user, pass].allSatisfy({ $0.utf8.count <= 255 && !$0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) }) else {
            throw ServiceFailure("unsafeConfiguration", "LAN requires two distinct allocated ports and valid optional HTTP/SOCKS credentials.")
        }
        socksPort = socks; httpPort = http; username = user; password = pass
    }

    fileprivate var users: [[String: String]] {
        authenticated ? [["username": username, "password": password]] : []
    }
    fileprivate var accounts: [[String: String]] {
        authenticated ? [["user": username, "pass": password]] : []
    }
}

/// Validate complete generated LAN shapes before giving their listener fields a
/// narrow exception to the ordinary loopback policy. The returned copy is ONLY
/// for subsequent validation; the unmodified original is what the core runs.
public enum LANPolicy {
    public static let allowedSources = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"]
    private static let tags = ["socks-lan", "http-lan"]

    private static func require(_ condition: @autoclosure () -> Bool) throws {
        guard condition() else {
            throw ServiceFailure("unsafeConfiguration", "LAN listeners, authentication and source restrictions must match the allocated session configuration.")
        }
    }

    public static func configurationForValidation(_ original: [String: Any], core: String, mode: String, lan: LANConfiguration) throws -> [String: Any] {
        var root = original
        if core == "mihomo" {
            try validateMihomo(root, lan: lan)
            // Every nested value of these two simple listener dictionaries was
            // checked below; arbitrary/nested listeners remain forbidden.
            root.removeValue(forKey: "listeners")
            return root
        }
        try require(core == "keqrnel")
        if mode == "proxy" {
            guard var inbounds = root["inbounds"] as? [[String: Any]] else { try require(false); return root }
            try validateSingBox(inbounds, root: root, lan: lan)
            for index in inbounds.indices where tags.contains(inbounds[index]["tag"] as? String ?? "") {
                inbounds[index]["listen"] = "127.0.0.1"
            }
            root["inbounds"] = inbounds
        } else {
            guard var outbounds = root["outbounds"] as? [[String: Any]] else { try require(false); return root }
            let bridgeIndices = outbounds.indices.filter { outbounds[$0]["type"] as? String == "xray" && outbounds[$0]["tag"] as? String == "proxy" }
            try require(bridgeIndices.count == 1)
            let index = bridgeIndices[0]
            guard var xray = outbounds[index]["xray"] as? [String: Any],
                  var inbounds = xray["inbounds"] as? [[String: Any]] else { try require(false); return root }
            try validateXray(inbounds, xray: xray, lan: lan)
            for inbound in inbounds.indices where tags.contains(inbounds[inbound]["tag"] as? String ?? "") {
                inbounds[inbound]["listen"] = "127.0.0.1"
            }
            xray["inbounds"] = inbounds; outbounds[index]["xray"] = xray; root["outbounds"] = outbounds
        }
        return root
    }

    private static func validateSingBox(_ inbounds: [[String: Any]], root: [String: Any], lan: LANConfiguration) throws {
        let selected = inbounds.filter { tags.contains($0["tag"] as? String ?? "") }
        try require(selected.count == 2)
        for (index, tag) in tags.enumerated() {
            let matches = selected.filter { $0["tag"] as? String == tag }
            try require(matches.count == 1)
            let inbound = matches[0]
            let expected: [String: Any] = ["type": index == 0 ? "socks" : "http", "tag": tag,
                "listen": "0.0.0.0", "listen_port": index == 0 ? lan.socksPort : lan.httpPort]
            try require(Set(inbound.keys).isSubset(of: Set(expected.keys).union(["users"])) && expected.allSatisfy { jsonEqual(inbound[$0.key], $0.value) })
            try require(jsonEqual(inbound["users"] ?? [], lan.users))
        }
        let route = root["route"] as? [String: Any]
        let rules = route?["rules"] as? [[String: Any]] ?? []
        try require(rules.count >= 2)
        try require(jsonEqual(rules[0], ["inbound": tags, "source_ip_cidr": allowedSources, "outbound": "proxy"]))
        try require(jsonEqual(rules[1], ["inbound": tags, "outbound": "block"]))
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        try require(outbounds.contains { $0["tag"] as? String == "proxy" && $0["type"] as? String == "xray" })
        try require(outbounds.contains { $0["tag"] as? String == "block" && $0["type"] as? String == "block" })
    }

    private static func validateXray(_ inbounds: [[String: Any]], xray: [String: Any], lan: LANConfiguration) throws {
        let selected = inbounds.filter { tags.contains($0["tag"] as? String ?? "") }
        try require(selected.count == 2)
        for (index, tag) in tags.enumerated() {
            let matches = selected.filter { $0["tag"] as? String == tag }
            try require(matches.count == 1)
            let inbound = matches[0]
            try require(Set(inbound.keys).isSubset(of: ["tag", "listen", "port", "protocol", "settings", "sniffing"]))
            try require(inbound["listen"] as? String == "0.0.0.0" && inbound["port"] as? Int == (index == 0 ? lan.socksPort : lan.httpPort) && inbound["protocol"] as? String == (index == 0 ? "socks" : "http"))
            var expected: [String: Any] = index == 0 ? ["auth": lan.authenticated ? "password" : "noauth", "udp": true] : ["allowTransparent": false]
            if lan.authenticated { expected["accounts"] = lan.accounts }
            try require(jsonEqual(inbound["settings"], expected))
            // Retained in the validation copy, so nested path/script options
            // still pass through the general policy rather than being skipped.
            if let sniffing = inbound["sniffing"] as? [String: Any] {
                try require(Set(sniffing.keys) == Set(["enabled", "destOverride", "routeOnly"]))
                try require(sniffing["enabled"] is Bool && sniffing["routeOnly"] is Bool && sniffing["destOverride"] as? [String] == ["http", "tls", "quic"])
            } else { try require(inbound["sniffing"] == nil) }
        }
        let routing = xray["routing"] as? [String: Any]
        var rules = routing?["rules"] as? [[String: Any]] ?? []
        // Upstream's global special-address block precedes LAN admission. It
        // can only deny traffic and must retain its exact bounded shape.
        if var first = rules.first {
            first.removeValue(forKey: "ruleTag")
            let outbounds = xray["outbounds"] as? [[String: Any]] ?? []
            if let blocked = first["outboundTag"] as? String,
               jsonEqual(first, ["type": "field", "ip": ["169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"], "outboundTag": blocked]),
               outbounds.contains(where: { $0["tag"] as? String == blocked && $0["protocol"] as? String == "blackhole" }) {
                rules.removeFirst()
            }
        }
        try require(rules.count >= 2)
        guard let target = rules[0]["outboundTag"] as? String, let blocked = rules[1]["outboundTag"] as? String else { try require(false); return }
        var allow = rules[0], deny = rules[1]
        allow.removeValue(forKey: "ruleTag"); deny.removeValue(forKey: "ruleTag")
        try require(jsonEqual(allow, ["type": "field", "inboundTag": tags, "source": allowedSources, "outboundTag": target]))
        try require(jsonEqual(deny, ["type": "field", "inboundTag": tags, "network": "tcp,udp", "outboundTag": blocked]))
        let outbounds = xray["outbounds"] as? [[String: Any]] ?? []
        try require(outbounds.contains { $0["tag"] as? String == target && !["freedom", "blackhole", "dns", "loopback"].contains($0["protocol"] as? String ?? "") })
        try require(outbounds.contains { $0["tag"] as? String == blocked && $0["protocol"] as? String == "blackhole" })
    }

    private static func validateMihomo(_ root: [String: Any], lan: LANConfiguration) throws {
        // Global/direct mode bypasses rule matching, including the source ACL.
        try require(root["mode"] == nil || root["mode"] as? String == "rule")
        try require(root["allow-lan"] as? Bool != true && root["bind-address"] as? String == "127.0.0.1")
        try require(root["skip-auth-prefixes"] == nil || jsonEqual(root["skip-auth-prefixes"], []))
        guard let listeners = root["listeners"] as? [[String: Any]], listeners.count == 2,
              let subrules = root["sub-rules"] as? [String: Any],
              let rules = subrules["keq-lan"] as? [String], rules.count == allowedSources.count + 1 else { try require(false); return }
        for (index, name) in ["keq-lan-socks", "keq-lan-http"].enumerated() {
            let matches = listeners.filter { $0["name"] as? String == name }
            try require(matches.count == 1)
            var expected: [String: Any] = ["name": name, "type": index == 0 ? "socks" : "http", "listen": "0.0.0.0",
                "port": String(index == 0 ? lan.socksPort : lan.httpPort), "rule": "keq-lan", "users": lan.users]
            if index == 0 { expected["udp"] = true }
            try require(jsonEqual(matches[0], expected))
        }
        let first = rules[0].components(separatedBy: ",")
        try require(first.count == 3)
        let target = first[2]
        let targets = ((root["proxies"] as? [[String: Any]] ?? []) + (root["proxy-groups"] as? [[String: Any]] ?? [])).compactMap { $0["name"] as? String }
        try require(!target.isEmpty && targets.contains(target) && !["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(target.uppercased()))
        try require(rules == allowedSources.map { "SRC-IP-CIDR,\($0),\(target)" } + ["MATCH,REJECT"])
    }
}
