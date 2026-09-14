import Foundation
import NetworkServiceKit

// No core is started: exercise the independent native trust boundary using
// direct session configurations, including inputs the importer already removes.
func runAuxiliaryServiceChecks() -> Int {
    var checks = 0
    let secret = "0123456789abcdef"
    func config(_ core: String, _ mode: String) -> [String: Any] {
        if core == "mihomo" {
            return ["external-controller": "127.0.0.1:9090", "secret": secret,
                    "geodata-mode": true, "geo-auto-update": false, "tun": ["enable": mode == "tun"]]
        }
        return ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]],
                "inbounds": mode == "tun" ? [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30"]]] : []]
    }
    func check(_ value: [String: Any], _ core: String, _ mode: String, allowed: Bool, label: String) {
        do {
            try ConfigPolicy.validateJSON(value, core: core, mode: mode, ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
            guard allowed else { fputs("FAIL: accepted auxiliary service \(label)\n", stderr); exit(1) }
        } catch let error as ServiceFailure {
            guard !allowed && error.code == "unsafeConfiguration" else {
                fputs("FAIL: auxiliary service \(label): \(error.code)\n", stderr); exit(1)
            }
        } catch { fputs("FAIL: auxiliary service \(label): \(error)\n", stderr); exit(1) }
        checks += 1
    }
    for mode in ["proxy", "tun"] {
        let mihomo = config("mihomo", mode)
        for (key, value) in ["ss-config": "ss://fixture@0.0.0.0:23456", "vmess-config": ["port": 23456],
                             "tuic-server": ["enable": true, "listen": "127.0.0.1:23456"],
                             "iptables": ["enable": true]] as [String: Any] {
            var bad = mihomo; bad[key] = value
            check(bad, "mihomo", mode, allowed: false, label: key)
        }
        for write in [true, 1, "true"] as [Any] {
            var bad = mihomo; bad["ntp"] = ["enable": true, "write-to-system": write]
            check(bad, "mihomo", mode, allowed: false, label: "clock write")
        }
        var safe = mihomo
        safe["ntp"] = ["enable": true, "write-to-system": false]
        safe["hosts"] = ["webhook": "192.0.2.1", "reverse": "192.0.2.2", "ss-config": "192.0.2.3"]
        safe["proxies"] = [["name": "tuic-server", "type": "socks5", "server": "example.test", "port": 443,
                            "username": "iptables", "password": "write-to-system"]]
        check(safe, "mihomo", mode, allowed: true, label: "normal resolver, names and credentials")

        let keqrnel = config("keqrnel", mode)
        for value in [["tag": "reverse-tunnel"], [:]] as [[String: Any]] {
            var bad = keqrnel
            bad["outbounds"] = [["type": "xray", "xray": ["outbounds": [["protocol": "vless", "settings": ["reverse": value]]]]]]
            check(bad, "keqrnel", mode, allowed: false, label: "VLESS reverse")
        }
        for value in ["https://example.test/connection", ["url": "https://example.test/connection"], ""] as [Any] {
            var bad = keqrnel
            bad["outbounds"] = [["type": "xray", "xray": ["routing": ["rules": [["webhook": value]]]]]]
            check(bad, "keqrnel", mode, allowed: false, label: "routing webhook")
        }
        // Go JSON structs also accept aliases; dictionaries can contain both
        // canonical and differently cased keys, regardless of iteration order.
        for xray in [
            ["outbounds": [["Protocol": "vless", "Settings": ["Reverse": ["tag": "remote"]]]]],
            ["outbounds": [["protocol": "vless", "settings": [:], "SETTINGS": ["reverse": ["tag": "remote"]]]]],
            ["Outbounds": [["protocol": "vless", "settings": ["reverse": ["tag": "remote"]]]]],
            ["routing": ["Rules": [["Webhook": ["url": "https://example.test/log"]]]]],
            ["routing": ["rules": [], "RULES": [["webhook": ["url": "https://example.test/log"]]]]],
            ["Routing": ["rules": [["webhook": ["url": "https://example.test/log"]]]]],
        ] as [[String: Any]] {
            for key in ["xray", "Xray"] {
                var bad = keqrnel
                bad["outbounds"] = [["type": "xray", key: xray]]
                check(bad, "keqrnel", mode, allowed: false, label: "Xray structural aliases")
            }
        }
        var collision = keqrnel
        collision["outbounds"] = [["type": "xray", "xray": [:], "XRAY": [
            "routing": ["rules": [["webhook": ["url": "https://example.test/log"]]]]]]]
        check(collision, "keqrnel", mode, allowed: false, label: "Xray root alias collision")
        var safeXray = keqrnel
        safeXray["outbounds"] = [["type": "xray", "xray": [
            "dns": ["hosts": ["webhook": "192.0.2.1", "reverse": "192.0.2.2", "Reverse": "192.0.2.3", "Webhook": "192.0.2.4"]],
            "outbounds": [["protocol": "vless", "tag": "reverse", "settings": ["address": "example.test", "port": 443, "id": "webhook"]]],
            "routing": ["rules": [["domain": ["domain:webhook"], "outboundTag": "reverse"]]]]]]
        check(safeXray, "keqrnel", mode, allowed: true, label: "Xray domain and tag data")
    }
    return checks
}
