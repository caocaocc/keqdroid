import Foundation

public struct SessionRequest {
    public let id: String
    public let mode: String
    public let core: String
    public let configurations: [String: String]
    public let socksPort: Int
    public let httpPort: Int
    public let apiPort: Int
    public let apiSecret: String
    public let infoPort: Int?
    public let systemProxy: Bool
    public let blockIpv6Leak: Bool
    public let contextID: String?
    public let dnsAddress: String?

    public init(arguments: [String: Any]) throws {
        guard arguments["protocolVersion"] as? Int == ServicePaths.protocolVersion else { throw ServiceFailure("protocolMismatch", "Install matching application and network service versions.") }
        guard let identifier = arguments["sessionId"] as? String, identifier.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil else { throw ServiceFailure("invalidRequest", "sessionId must be an opaque alphanumeric identifier.") }
        id = identifier
        guard let mode = arguments["connectionMode"] as? String, ["proxy", "tun"].contains(mode),
              let core = arguments["core"] as? String, ["keqrnel", "mihomo", "awg"].contains(core) else { throw ServiceFailure("unsupportedCore", "Unsupported network mode or core.") }
        self.mode = mode; self.core = core
        func port(_ key: String) throws -> Int {
            guard let value = arguments[key] as? Int, (1024...65535).contains(value) else { throw ServiceFailure("invalidPort", "\(key) must be an unprivileged TCP port.") }
            return value
        }
        socksPort = try port("socksPort"); httpPort = try port("httpPort"); apiPort = try port("apiPort")
        infoPort = core == "awg" ? try port("wireproxyInfoPort") : nil
        let ports = [socksPort, httpPort, apiPort] + (infoPort.map { [$0] } ?? [])
        guard Set(ports).count == ports.count else { throw ServiceFailure("invalidPort", "Local ports must be distinct.") }
        guard let secret = arguments["apiSecret"] as? String, secret.count >= 16, secret.count <= 256 else { throw ServiceFailure("invalidRequest", "The local API requires a per-session secret.") }
        apiSecret = secret
        systemProxy = arguments["systemProxy"] as? Bool ?? true
        blockIpv6Leak = arguments["blockIpv6Leak"] as? Bool ?? false
        contextID = arguments["contextId"] as? String
        dnsAddress = arguments["dnsAddress"] as? String
        if mode == "proxy", arguments["contextId"] != nil || arguments["dnsAddress"] != nil {
            throw ServiceFailure("invalidRequest", "Proxy sessions cannot change system DNS or use a TUN network context.")
        }
        if mode == "tun" {
            guard contextID != nil, let dnsAddress, isIPAddress(dnsAddress) else { throw ServiceFailure("invalidDNS", "TUN requires a prepared network context and virtual DNS address.") }
            if core != "mihomo", dnsAddress != "172.19.0.2" { throw ServiceFailure("invalidDNS", "Unexpected virtual tunnel DNS address.") }
        }
        guard let configs = arguments["configurations"] as? [String: String], !configs.isEmpty else { throw ServiceFailure("invalidConfiguration", "Missing core configuration.") }
        let expected: Set<String> = core == "awg" ? (mode == "tun" ? ["wireproxy", "keqrnel"] : ["wireproxy"]) : [core]
        guard Set(configs.keys) == expected else { throw ServiceFailure("invalidConfiguration", "Unexpected core configuration set.") }
        for (name, text) in configs {
            guard !text.isEmpty, text.utf8.count <= 2 * 1024 * 1024 else { throw ServiceFailure("invalidConfiguration", "Core configuration is empty or too large.") }
            if name == "wireproxy" { try ConfigPolicy.validateWireproxy(text, socksPort: socksPort, httpPort: httpPort) }
            else {
                guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw ServiceFailure("invalidConfiguration", "Core configuration must be a JSON object.") }
                try ConfigPolicy.validateJSON(object, core: name, mode: mode, ports: Set(ports), apiPort: apiPort, secret: secret)
            }
        }
        configurations = configs
    }
}

public enum ConfigPolicy {
    public static func validateIPv6Protection(configurations: [String: String], core: String, required: Bool) throws {
        guard required else { return }
        guard core != "mihomo", let text = configurations["keqrnel"],
              let config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let tuns = config["inbounds"] as? [[String: Any]],
              tuns.contains(where: { $0["type"] as? String == "tun" && $0["auto_route"] as? Bool == true && ($0["address"] as? [String] ?? []).contains("fdfe:dcba:9876::1/126") }),
              let route = config["route"] as? [String: Any], let rules = route["rules"] as? [[String: Any]],
              rules.contains(where: { Set($0.keys) == Set(["ip_cidr", "outbound"]) && $0["ip_cidr"] as? [String] == ["::/0"] && $0["outbound"] as? String == "block" }),
              let outbounds = config["outbounds"] as? [[String: Any]],
              outbounds.contains(where: { $0["type"] as? String == "block" && $0["tag"] as? String == "block" }) else {
            throw ServiceFailure("ipv6ProtectionUnavailable", "IPv6 leak protection requires a managed IPv6 TUN address and an unconditional IPv6 block rule. This core configuration cannot provide it.")
        }
    }

    /// File paths and executable hooks are not part of the privileged API.
    /// Rule process paths and HTTP URL paths are match/transport data, not files.
    public static func validateJSON(_ root: [String: Any], core: String, mode: String, ports: Set<Int>, apiPort: Int, secret: String) throws {
        var count = 0
        let forbidden: Set<String> = ["script", "scripts", "command", "commands", "exec", "externalui", "externaluiurl", "externaluidownloadurl", "geoxurl", "geoupdateinterval", "geodataupdateinterval", "geodataupdate", "externalcontrollerunix", "externalcontrollerpipe", "externalcontrollertls", "controllerunix", "workingdirectory", "directory", "dir", "tunfd", "filedescriptor", "certificatefile", "keyfile", "privatekeyfile", "publickeyfile", "masterkeylog", "keylog", "keylogwriter", "planet", "listeners", "tunnels", "output", "access", "error"]
        let pathExceptions: Set<String> = ["processpath", "processpathregex"]
        func meaningful(_ value: Any) -> Bool {
            if let value = value as? String { return !value.isEmpty && value != "none" && value != "stderr" && value != "stdout" }
            if value is NSNull { return false }
            if let value = value as? Bool { return value }
            if let value = value as? [Any] { return !value.isEmpty }
            if let value = value as? [String: Any] { return !value.isEmpty }
            return true
        }
        func walk(_ node: Any, parents: [String], depth: Int) throws {
            count += 1
            guard depth < 48, count < 100_000 else { throw ServiceFailure("invalidConfiguration", "Configuration nesting or size exceeds limits.") }
            if let dictionary = node as? [String: Any] {
                if parents.last?.lowercased() == "xray" {
                    // Xray's Commander/HandlerService can add arbitrary new
                    // inbounds after validation and has its own unauthenticated
                    // listener. Only the routing client configuration is used.
                    let allowed: Set<String> = ["log", "dns", "inbounds", "outbounds", "routing", "policy"]
                    guard Set(dictionary.keys).isSubset(of: allowed) else {
                        throw ServiceFailure("unsafeConfiguration", "Embedded Xray API, metrics, observatory and other auxiliary services are not permitted.")
                    }
                }
                if let providerMap = parents.last, ["proxy-providers", "rule-providers"].contains(providerMap) {
                    guard dictionary.keys.allSatisfy({ !$0.isEmpty && $0.count < 129 && !$0.contains("/") && !$0.contains("\\") && $0 != ".." }) else { throw ServiceFailure("unsafeConfiguration", "Provider names cannot contain filesystem paths.") }
                }
                for (key, value) in dictionary {
                    let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                    let parent = parents.last?.lowercased() ?? ""
                    if normalized == "inbounds" {
                        guard let inbounds = value as? [[String: Any]] else { throw ServiceFailure("unsafeConfiguration", "Inbound definitions must be a validated array.") }
                        for inbound in inbounds {
                            if parents.isEmpty {
                                guard let type = inbound["type"] as? String, ["tun", "socks", "http", "mixed"].contains(type) else { throw ServiceFailure("unsafeConfiguration", "Only managed TUN and local SOCKS/HTTP inbounds are permitted.") }
                                let allowed: Set<String> = type == "tun" ? ["type", "tag", "address", "auto_route", "stack", "mtu", "strict_route"] : ["type", "tag", "listen", "listen_port", "users"]
                                guard Set(inbound.keys).isSubset(of: allowed) else { throw ServiceFailure("unsafeConfiguration", "Unmanaged inbound options are not permitted.") }
                                if type != "tun" {
                                    guard ["127.0.0.1", "::1"].contains(inbound["listen"] as? String ?? ""), let port = inbound["listen_port"] as? Int, ports.contains(port) else { throw ServiceFailure("unsafeConfiguration", "A local inbound must declare its allocated loopback listener.") }
                                }
                            } else {
                                let allowed: Set<String> = ["tag", "listen", "port", "protocol", "settings", "sniffing"]
                                guard ["socks", "http"].contains(inbound["protocol"] as? String ?? ""),
                                      Set(inbound.keys).isSubset(of: allowed), ["127.0.0.1", "::1"].contains(inbound["listen"] as? String ?? ""),
                                      let port = inbound["port"] as? Int, ports.contains(port) else { throw ServiceFailure("unsafeConfiguration", "Embedded Xray may expose only plain local SOCKS/HTTP inbounds, without server transports or TLS.") }
                            }
                        }
                    }
                    let httpPath = normalized == "path" && ["wssettings", "httpupgrade", "httpupgradesettings", "xhttpsettings", "http", "httpupgrade", "ws", "grpc", "transport", "httpheaders", "httpsettings"].contains(parent)
                    let providerPath = normalized == "path" && (parents.contains("proxy-providers") || parents.contains("rule-providers"))
                    let nonPathContainer = ["profile", "cachefile"].contains(normalized) && value is [String: Any]
                    if providerPath {
                        guard let path = value as? String, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."), !path.contains("\0"), path.count < 512 else { throw ServiceFailure("unsafeConfiguration", "Provider cache paths must remain inside the private session directory.") }
                    }
                    // Some TLS implementations interpret these values as a
                    // filename unless inline PEM is supplied. Never let a root
                    // core read caller-selected certificate/private-key files.
                    if (["certificate", "clientcertificate", "clientkey"].contains(normalized) || normalized == "privatekey" && (["tls", "tlssettings", "certificates"].contains(parent) || dictionary["certificate"] != nil || dictionary["type"] as? String == "ssh")), let text = value as? String,
                       !text.isEmpty, !text.contains("-----BEGIN ") {
                        throw ServiceFailure("unsafeConfiguration", "TLS/SSH keys and certificates must be inline PEM, not filesystem references.")
                    }
                    if normalized == "type", value as? String == "file", parents.contains("proxy-providers") || parents.contains("rule-providers") { throw ServiceFailure("unsafeConfiguration", "External provider files cannot be read by the privileged core.") }
                    if meaningful(value) && !pathExceptions.contains(normalized) && !httpPath && !providerPath && !nonPathContainer && (forbidden.contains(normalized) || normalized.hasSuffix("path") || normalized.hasSuffix("file") || normalized.hasSuffix("filepath")) {
                        throw ServiceFailure("unsafeConfiguration", "File or executable option is not allowed in privileged configuration: \(key)")
                    }
                    if ["listen", "listenaddress", "bindaddress"].contains(normalized), let address = value as? String {
                        let host = address.components(separatedBy: ":").first ?? ""
                        guard address == "127.0.0.1" || address == "::1" || host == "127.0.0.1" || address.hasPrefix("[::1]:") else { throw ServiceFailure("unsafeConfiguration", "Core listeners must bind to loopback.") }
                    }
                    if ["externalcontroller", "externalcontrolleraddress"].contains(normalized) {
                        guard value as? String == "127.0.0.1:\(apiPort)" else { throw ServiceFailure("unsafeConfiguration", "The local control API must use the allocated loopback port.") }
                    }
                    if normalized == "listenport", let number = value as? Int, !ports.contains(number) { throw ServiceFailure("unsafeConfiguration", "Unexpected listener port.") }
                    if normalized == "port", parents.contains("inbounds"), let number = value as? Int, !ports.contains(number) { throw ServiceFailure("unsafeConfiguration", "Unexpected embedded listener port.") }
                    if ["socksport", "mixedport", "redirport", "tproxyport"].contains(normalized), let number = value as? Int, number != 0 && !ports.contains(number) { throw ServiceFailure("unsafeConfiguration", "Unexpected proxy port.") }
                    try walk(value, parents: parents + [key], depth: depth + 1)
                }
            } else if let array = node as? [Any] {
                for item in array { try walk(item, parents: parents, depth: depth + 1) }
            } else if let value = node as? String {
                let lower = value.lowercased()
                let field = parents.last?.lowercased() ?? ""
                let secretFields = ["password", "pass", "username", "user", "secret", "auth", "uuid", "id", "token"]
                if !secretFields.contains(field), lower.hasPrefix("file:") || lower.hasPrefix("ext:") || lower.hasPrefix("ext-ip:") {
                    throw ServiceFailure("unsafeConfiguration", "External filesystem resources are not permitted in privileged configuration.")
                }
                if core == "mihomo", parents.contains("rules") || parents.contains("sub-rules"), value.uppercased().contains("IP-ASN,") {
                    throw ServiceFailure("unsupportedGeoData", "IP-ASN rules require an ASN database that is not included in this macOS package.")
                }
            }
        }
        try walk(root, parents: [], depth: 0)
        if core == "keqrnel" {
            guard Set(root.keys).isSubset(of: ["log", "dns", "inbounds", "outbounds", "route", "experimental"]) else {
                throw ServiceFailure("unsafeConfiguration", "Only the managed core routing configuration is permitted; auxiliary services and endpoints are disabled.")
            }
            let experimental = root["experimental"] as? [String: Any]
            guard Set(experimental?.keys.map { $0 } ?? []).isSubset(of: ["clash_api", "cache_file"]) else {
                throw ServiceFailure("unsafeConfiguration", "Additional core management APIs are not permitted.")
            }
            let api = experimental?["clash_api"] as? [String: Any]
            guard api?["external_controller"] as? String == "127.0.0.1:\(apiPort)", api?["secret"] as? String == secret else { throw ServiceFailure("unsafeConfiguration", "The core API must require the session secret.") }
            let inbounds = root["inbounds"] as? [[String: Any]] ?? []
            let tuns = inbounds.filter { $0["type"] as? String == "tun" }
            guard (mode == "tun" && tuns.count == 1) || (mode == "proxy" && tuns.isEmpty) else { throw ServiceFailure("invalidConfiguration", "TUN configuration does not match the selected mode.") }
            if let tun = tuns.first {
                let addresses = tun["address"] as? [String] ?? []
                guard tun["auto_route"] as? Bool == true, addresses.contains("172.19.0.1/30"), addresses.allSatisfy({ $0 == "172.19.0.1/30" || $0.lowercased().hasPrefix("fd") && $0.contains("/") }), tun["interface_name"] == nil else { throw ServiceFailure("unsafeConfiguration", "The TUN must use the managed subnet and an automatically allocated utun interface.") }
            }
        } else {
            if mode == "tun", let providers = root["proxy-providers"] as? [String: Any], !providers.isEmpty {
                throw ServiceFailure("unsafeConfiguration", "TUN cannot load remote proxy providers after privileged configuration validation. Import and expand the provider into inline proxies first.")
            }
            guard root["external-controller"] as? String == "127.0.0.1:\(apiPort)", root["secret"] as? String == secret,
                  root["allow-lan"] as? Bool != true else { throw ServiceFailure("unsafeConfiguration", "Mihomo must use a private authenticated local API.") }
            guard root["geodata-mode"] as? Bool == true, root["geo-auto-update"] as? Bool == false else {
                throw ServiceFailure("unsupportedGeoData", "The installed macOS runtime provides geoip.dat/geosite.dat only. Enable geodata-mode and disable geo-auto-update; MMDB and automatic root data downloads are unsupported.")
            }
            let rules = root["rules"] as? [String] ?? []
            guard !rules.contains(where: { $0.uppercased().contains("IP-ASN,") }) else {
                throw ServiceFailure("unsupportedGeoData", "IP-ASN rules require an ASN database that is not included in this macOS package.")
            }
            let tun = root["tun"] as? [String: Any] ?? [:]
            guard (tun["enable"] as? Bool ?? false) == (mode == "tun"), tun["device"] == nil else { throw ServiceFailure("unsafeConfiguration", "Mihomo must allocate its own utun device.") }
        }
    }

    public static func validateWireproxy(_ text: String, socksPort: Int, httpPort: Int) throws {
        let sections: Set<String> = ["interface", "peer", "socks5", "http"]
        let allowed: Set<String> = ["privatekey", "address", "dns", "mtu", "table", "publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive", "listenport", "jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "s3", "s4", "bindaddress", "username", "password"]
        var section = "", seenBindings: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                guard sections.contains(section) else { throw ServiceFailure("unsafeConfiguration", "Unsupported wireproxy section.") }
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !section.isEmpty, pair.count == 2, allowed.contains(pair[0].lowercased()) else { throw ServiceFailure("unsafeConfiguration", "Unsupported wireproxy option or executable hook.") }
            if pair[0].lowercased() == "bindaddress" {
                let expected = section == "socks5" ? "127.0.0.1:\(socksPort)" : "127.0.0.1:\(httpPort)"
                guard ["socks5", "http"].contains(section), pair[1] == expected, seenBindings.insert(section).inserted else { throw ServiceFailure("unsafeConfiguration", "wireproxy must bind each proxy exactly once to its allocated loopback port.") }
            }
        }
        guard seenBindings.contains("socks5") else { throw ServiceFailure("invalidConfiguration", "wireproxy SOCKS listener is missing.") }
    }
}
