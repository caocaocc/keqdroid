import Foundation
import NetworkServiceKit

// Pure configuration validation: no core, listener or system network changes.
func runMihomoTransportPathChecks() -> Int {
    var checks = 0
    let secret = "0123456789abcdef"
    func config(_ proxies: Any, mode: String = "proxy") -> [String: Any] {
        ["proxies": proxies, "external-controller": "127.0.0.1:9090", "secret": secret,
         "geodata-mode": true, "geo-auto-update": false, "tun": ["enable": mode == "tun"]]
    }
    func validate(_ value: [String: Any], mode: String = "proxy", core: String = "mihomo") throws {
        try ConfigPolicy.validateJSON(value, core: core, mode: mode, ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
    }
    func accepts(_ value: [String: Any], _ label: String, mode: String = "proxy") {
        do { try validate(value, mode: mode); checks += 1 }
        catch { fputs("FAIL: rejected Mihomo HTTP path \(label): \(error.localizedDescription)\n", stderr); exit(1) }
    }
    func rejects(_ value: [String: Any], _ label: String, core: String = "mihomo") {
        do { try validate(value, core: core); fputs("FAIL: accepted unsafe Mihomo path \(label)\n", stderr); exit(1) }
        catch let error as ServiceFailure {
            guard error.code == "unsafeConfiguration" else { fputs("FAIL: wrong rejection for \(label): \(error.code)\n", stderr); exit(1) }
            checks += 1
        } catch { fputs("FAIL: unexpected rejection for \(label)\n", stderr); exit(1) }
    }
    func proxy(_ type: String, _ network: String, _ options: String, _ path: Any) -> [String: Any] {
        ["type": type, "network": network, options: ["path": path]]
    }
    let transports = [("vless", "xhttp", "xhttp-opts"), ("vless", "ws", "ws-opts"),
                      ("vmess", "ws", "ws-opts"), ("trojan", "ws", "ws-opts"),
                      ("vless", "h2", "h2-opts"), ("vmess", "h2", "h2-opts"),
                      ("vless", "http", "http-opts"), ("vmess", "http", "http-opts")]
    let paths = ["", "/", "/transport?test=1", "/custom%20path", "/etc/hosts", "/" + String(repeating: "a", count: 2047)]
    for mode in ["proxy", "tun"] {
        for (type, network, options) in transports {
            for path in paths {
                let value: Any = options == "http-opts" ? [path] : path
                accepts(config([proxy(type, network, options, value)], mode: mode), "\(type)/\(network) in \(mode)", mode: mode)
            }
        }
        let download: [String: Any] = ["type": "vless", "network": "xhttp", "xhttp-opts": ["path": "/upload", "download-settings": ["path": "/download"]]]
        accepts(config([download], mode: mode), "XHTTP download in \(mode)", mode: mode)
        let upgrade: [String: Any] = ["type": "vless", "network": "ws", "ws-opts": ["path": "/upgrade", "v2ray-http-upgrade": true]]
        accepts(config([upgrade], mode: mode), "HTTP upgrade in \(mode)", mode: mode)
    }
    for malformed in [NSNull(), true, 1, ["/path"], ["path": "/path"], "relative", "file:///etc/hosts", "/" + String(repeating: "a", count: 2048), "/line\n", "/nul\0", "/del\u{7f}", "/encoded%00", "/encoded%0a", "/invalid%XX"] as [Any] {
        rejects(config([proxy("vless", "xhttp", "xhttp-opts", malformed)]), "invalid scalar")
        rejects(config([proxy("vless", "http", "http-opts", [malformed])]), "invalid list member")
        rejects(config([["type": "vless", "network": "xhttp", "xhttp-opts": ["download-settings": ["path": malformed]]]]), "invalid download path")
    }
    for malformed in [NSNull(), true, 1, "/path", ["nested": ["/path"]]] as [Any] {
        rejects(config([proxy("vless", "http", "http-opts", malformed)]), "invalid list shape")
    }
    let good = proxy("vless", "xhttp", "xhttp-opts", "/transport")
    for disguised in [good, [[good]], ["nested": [good]], [["nested": good]],
        [proxy("trojan", "xhttp", "xhttp-opts", "/transport")], [proxy("vless", "tcp", "xhttp-opts", "/transport")],
        [["type": "vless", "network": "xhttp", "xhttp-opts": [["path": "/transport"]]]],
        [["type": "vless", "network": "xhttp", "xhttp-opts": ["nested": ["path": "/etc/hosts"]]]],
        [["type": "vless", "network": "xhttp", "xhttp-opts": ["download-settings": [["path": "/transport"]]]]],
        [["type": "vless", "network": "ws", "ws-opts": ["download-settings": ["path": "/transport"]]]]
    ] as [Any] { rejects(config(disguised), "wrong structural scope") }
    rejects(config([good]), "non-Mihomo core", core: "keqrnel")
    for (key, value) in ["certificate-path": "/etc/hosts", "private-key": "/etc/private.pem", "command": "/bin/sh", "path": "/etc/hosts"] {
        var bad = good; bad[key] = value
        if key == "private-key" { bad["certificate"] = "-----BEGIN CERTIFICATE-----\nexample" }
        rejects(config([bad]), "filesystem/command next to legal transport")
    }
    return checks
}
