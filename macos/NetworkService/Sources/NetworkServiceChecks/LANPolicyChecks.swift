import Foundation
import NetworkServiceKit

// Pure JSON checks. Never open a listener, start a core or change the network.
func runLANPolicyChecks() -> Int {
    var checks = 0
    let secret = "0123456789abcdef"
    let reserved: Set<Int> = [2080, 2081, 9090]
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: LAN \(label)\n", stderr); exit(1) }
        checks += 1
    }
    func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); fputs("FAIL: LAN accepted \(label)\n", stderr); exit(1) }
        catch let error as ServiceFailure { expect(error.code == "unsafeConfiguration", "wrong rejection code for \(label)") }
        catch { fputs("FAIL: LAN unexpected error for \(label)\n", stderr); exit(1) }
    }
    func descriptor(_ authenticated: Bool) -> [String: Any] {
        ["socksPort": 11080, "httpPort": 18080, "username": authenticated ? "test-user" : "", "password": authenticated ? "test-password" : ""]
    }
    func config(_ core: String, _ mode: String, _ auth: Bool) -> [String: Any] {
        let users = auth ? [["username": "test-user", "password": "test-password"]] : []
        if core == "mihomo" {
            return ["mode": "rule", "allow-lan": false, "bind-address": "127.0.0.1",
                "socks-port": 2080, "port": 2081, "external-controller": "127.0.0.1:9090", "secret": secret,
                "geodata-mode": true, "geo-auto-update": false, "tun": ["enable": mode == "tun"],
                "proxies": [["name": "proxy", "type": "trojan", "server": "node.example", "port": 443]],
                "listeners": [
                    ["name": "keq-lan-socks", "type": "socks", "listen": "0.0.0.0", "port": "11080", "udp": true, "rule": "keq-lan", "users": users],
                    ["name": "keq-lan-http", "type": "http", "listen": "0.0.0.0", "port": "18080", "rule": "keq-lan", "users": users]],
                "sub-rules": ["keq-lan": LANPolicy.allowedSources.map { "SRC-IP-CIDR,\($0),proxy" } + ["MATCH,REJECT"]]]
        }
        let xrayRules: [[String: Any]] = [
            ["type": "field", "inboundTag": ["socks-lan", "http-lan"], "source": LANPolicy.allowedSources, "outboundTag": "proxy"],
            ["type": "field", "inboundTag": ["socks-lan", "http-lan"], "network": "tcp,udp", "outboundTag": "block"]]
        var xray: [String: Any] = ["outbounds": [["tag": "proxy", "protocol": "trojan"], ["tag": "block", "protocol": "blackhole"]], "routing": ["rules": xrayRules]]
        var root: [String: Any] = ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]]]
        if mode == "proxy" {
            root["inbounds"] = [
                ["type": "socks", "tag": "socks-lan", "listen": "0.0.0.0", "listen_port": 11080, "users": users],
                ["type": "http", "tag": "http-lan", "listen": "0.0.0.0", "listen_port": 18080, "users": users]]
            root["route"] = ["rules": [
                ["inbound": ["socks-lan", "http-lan"], "source_ip_cidr": LANPolicy.allowedSources, "outbound": "proxy"],
                ["inbound": ["socks-lan", "http-lan"], "outbound": "block"]]]
        } else {
            var socks: [String: Any] = ["auth": auth ? "password" : "noauth", "udp": true]
            var http: [String: Any] = ["allowTransparent": false]
            if auth { socks["accounts"] = [["user": "test-user", "pass": "test-password"]]; http["accounts"] = socks["accounts"] }
            xray["inbounds"] = [
                ["tag": "socks-lan", "listen": "0.0.0.0", "port": 11080, "protocol": "socks", "settings": socks],
                ["tag": "http-lan", "listen": "0.0.0.0", "port": 18080, "protocol": "http", "settings": http]]
            root["inbounds"] = [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30"]]]
        }
        root["outbounds"] = [["type": "xray", "tag": "proxy", "xray": xray], ["type": "block", "tag": "block"]]
        return root
    }
    for core in ["keqrnel", "mihomo"] {
        for mode in ["proxy", "tun"] {
            for auth in [false, true] {
                do {
                    let lan = try LANConfiguration(arguments: descriptor(auth), reservedPorts: reserved)
                    let good = config(core, mode, auth)
                    try ConfigPolicy.validateJSON(good, core: core, mode: mode, ports: reserved, apiPort: 9090, secret: secret, lan: lan)
                    checks += 1
                    rejects("LAN without explicit request permission") { try ConfigPolicy.validateJSON(good, core: core, mode: mode, ports: reserved, apiPort: 9090, secret: secret) }
                    let wrongAuth = try LANConfiguration(arguments: descriptor(!auth), reservedPorts: reserved)
                    rejects("descriptor and core authentication disagree") { try ConfigPolicy.validateJSON(good, core: core, mode: mode, ports: reserved, apiPort: 9090, secret: secret, lan: wrongAuth) }
                    var badAPI = good
                    if core == "mihomo" { badAPI["external-controller"] = "0.0.0.0:9090" }
                    else { badAPI["experimental"] = ["clash_api": ["external_controller": "0.0.0.0:9090", "secret": secret]] }
                    rejects("public controller next to valid LAN") { try ConfigPolicy.validateJSON(badAPI, core: core, mode: mode, ports: reserved, apiPort: 9090, secret: secret, lan: lan) }
                    var request: [String: Any] = ["protocolVersion": ServicePaths.protocolVersion, "sessionId": "lan-contract", "connectionMode": mode, "core": core,
                        "socksPort": 2080, "httpPort": 2081, "apiPort": 9090, "apiSecret": secret, "lan": descriptor(auth),
                        "configurations": [core: String(data: try JSONSerialization.data(withJSONObject: good), encoding: .utf8)!]]
                    if mode == "tun" { request["contextId"] = "test-context"; request["dnsAddress"] = core == "mihomo" ? "198.18.0.2" : "172.19.0.2" }
                    let parsed = try SessionRequest(arguments: request)
                    expect(parsed.allListenerPorts == [2080, 2081, 9090, 11080, 18080], "all listeners are checked for availability")
                    expect(parsed.lanPorts == [11080, 18080], "LAN listener subset is exact")
                    expect(parsed.configurations == request["configurations"] as? [String: String], "validation never rewrites the executing configuration")
                } catch { fputs("FAIL: valid LAN \(core)/\(mode) rejected: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }
    for changes: [String: Any] in [["socksPort": 80], ["socksPort": 65536], ["socksPort": 2080], ["httpPort": 9090], ["httpPort": 11080], ["username": "only-user"], ["password": "only-password"], ["username": "a:b", "password": "p"], ["username": "a\nb", "password": "p"], ["username": " a ", "password": "p"], ["username": "u", "password": String(repeating: "中", count: 86)], ["command": "/bin/sh"]] {
        var bad = descriptor(false); changes.forEach { bad[$0.key] = $0.value }
        rejects("invalid descriptor") { _ = try LANConfiguration(arguments: bad, reservedPorts: reserved) }
    }
    do {
        let lan = try LANConfiguration(arguments: descriptor(false), reservedPorts: reserved)
        func rejectsConfig(_ root: [String: Any], core: String = "mihomo", mode: String = "proxy") {
            rejects("altered listener or source ACL") { try ConfigPolicy.validateJSON(root, core: core, mode: mode, ports: reserved, apiPort: 9090, secret: secret, lan: lan) }
        }
        let mihomo = config("mihomo", "proxy", false)
        for change: [String: Any] in [["listen": "::"], ["port": "9090"], ["type": "mixed"], ["users": [["username": "injected", "password": "p"]]], ["rule": "other"], ["proxy": "DIRECT"], ["path": "/etc/hosts"]] {
            var bad = mihomo; var listeners = bad["listeners"] as! [[String: Any]]
            change.forEach { listeners[0][$0.key] = $0.value }; bad["listeners"] = listeners
            rejectsConfig(bad)
        }
        for rules in [["MATCH,proxy"], ["SRC-IP-CIDR,0.0.0.0/0,proxy", "MATCH,REJECT"], LANPolicy.allowedSources.map { "SRC-IP-CIDR,\($0),DIRECT" } + ["MATCH,REJECT"], ["MATCH,REJECT"] + LANPolicy.allowedSources.map { "SRC-IP-CIDR,\($0),proxy" }] {
            var bad = mihomo; bad["sub-rules"] = ["keq-lan": rules]; rejectsConfig(bad)
        }
        for change: [String: Any] in [["mode": "global"], ["mode": "direct"], ["allow-lan": true], ["bind-address": "*"], ["skip-auth-prefixes": ["0.0.0.0/0"]], ["nested": ["listeners": [["listen": "0.0.0.0"]]]]] {
            var bad = mihomo; change.forEach { bad[$0.key] = $0.value }; rejectsConfig(bad)
        }
        var third = mihomo; var listeners = third["listeners"] as! [[String: Any]]; listeners.append(listeners[0]); third["listeners"] = listeners; rejectsConfig(third)
        for mode in ["proxy", "tun"] {
            let original = config("keqrnel", mode, false)
            for variant in 0..<4 {
                var bad = original
                var embedded = bad
                if mode == "tun" { embedded = (bad["outbounds"] as! [[String: Any]])[0]["xray"] as! [String: Any] }
                if variant < 2 {
                    var inbounds = embedded["inbounds"] as! [[String: Any]]
                    if variant == 0 { inbounds[0]["listen"] = "::" }
                    else { inbounds.append(inbounds[0]) }
                    embedded["inbounds"] = inbounds
                } else {
                    let routingKey = mode == "tun" ? "routing" : "route"
                    var routing = embedded[routingKey] as! [String: Any]
                    var rules = routing["rules"] as! [[String: Any]]
                    if variant == 2 { rules[0][mode == "tun" ? "source" : "source_ip_cidr"] = ["0.0.0.0/0"] }
                    else { rules.reverse() }
                    routing["rules"] = rules; embedded[routingKey] = routing
                }
                if mode == "tun" { var outbounds = bad["outbounds"] as! [[String: Any]]; outbounds[0]["xray"] = embedded; bad["outbounds"] = outbounds }
                else { bad = embedded }
                rejectsConfig(bad, core: "keqrnel", mode: mode)
            }
        }
        let tun = config("keqrnel", "tun", false)
        for target in ["block", "proxy"] {
            var modified = tun
            var outbounds = modified["outbounds"] as! [[String: Any]]
            var xray = outbounds[0]["xray"] as! [String: Any]
            var routing = xray["routing"] as! [String: Any]
            var rules = routing["rules"] as! [[String: Any]]
            rules.insert(["type": "field", "ruleTag": "block-special", "ip": ["169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"], "outboundTag": target], at: 0)
            routing["rules"] = rules; xray["routing"] = routing; outbounds[0]["xray"] = xray; modified["outbounds"] = outbounds
            if target == "block" {
                try ConfigPolicy.validateJSON(modified, core: "keqrnel", mode: "tun", ports: reserved, apiPort: 9090, secret: secret, lan: lan)
                checks += 1
            } else { rejectsConfig(modified, core: "keqrnel", mode: "tun") }
        }
    } catch { fputs("FAIL: LAN test setup: \(error.localizedDescription)\n", stderr); exit(1) }
    return checks
}
