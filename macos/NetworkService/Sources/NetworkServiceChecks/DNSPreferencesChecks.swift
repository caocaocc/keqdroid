import Foundation
import NetworkServiceKit

// DNS map keys are domain data, including names which resemble option names.
// Only parse synthetic configurations; no file targets, cores or network APIs run.
func runDNSPreferencesChecks() -> Int {
    var checks = 0
    let secret = "0123456789abcdef"
    let scopes = ["mihomo-hosts", "mihomo-policy", "xray-hosts", "singbox-predefined"]
    func config(_ scope: String, _ entries: Any, mode: String = "proxy") -> [String: Any] {
        if scope.hasPrefix("mihomo") {
            var value: [String: Any] = ["external-controller": "127.0.0.1:9090", "secret": secret,
                "geodata-mode": true, "geo-auto-update": false, "tun": ["enable": mode == "tun"]]
            if scope == "mihomo-hosts" { value["hosts"] = entries }
            else { value["dns"] = ["nameserver-policy": entries] }
            return value
        }
        var value: [String: Any] = ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]],
            "inbounds": [["type": "socks", "listen": "127.0.0.1", "listen_port": 2080]], "outbounds": [["type": "direct"]]]
        if mode == "tun" { value["inbounds"] = [["type": "tun", "auto_route": true, "address": ["172.19.0.1/30"]]] }
        if scope == "xray-hosts" { value["outbounds"] = [["type": "xray", "xray": ["dns": ["hosts": entries]]]] }
        else { value["dns"] = ["servers": [["type": "hosts", "tag": "keq-hosts", "predefined": entries]]] }
        return value
    }
    func check(_ value: [String: Any], _ scope: String, accept: Bool, mode: String = "proxy", label: String) {
        do {
            try ConfigPolicy.validateJSON(value, core: scope.hasPrefix("mihomo") ? "mihomo" : "keqrnel",
                mode: mode, ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
            guard accept else { fputs("FAIL: accepted unsafe DNS data: \(label)\n", stderr); exit(1) }
        } catch let error as ServiceFailure {
            guard !accept && error.code == "unsafeConfiguration" else {
                fputs("FAIL: DNS data \(label): \(error.localizedDescription)\n", stderr); exit(1)
            }
        } catch { fputs("FAIL: unexpected DNS data error: \(error)\n", stderr); exit(1) }
        checks += 1
    }
    for scope in scopes {
        let valid: Any = scope == "mihomo-policy" ? ["https://192.0.2.53/dns-query"] : ["192.0.2.42", "2001:db8::42"]
        for mode in ["proxy", "tun"] {
            for name in ["error", "path", "command", "listen", "external-controller", "printer.local"] {
                check(config(scope, [name: valid], mode: mode), scope, accept: true, mode: mode, label: "\(scope)/\(mode)/\(name)")
            }
        }
        for malformed in [NSNull(), false, 1, [], [false], ["command": "/bin/sh"], [["192.0.2.1"]], "", "file:///etc/hosts", "/etc/hosts", "ext:private.dat", "$(id)", "alias\n.example"] as [Any] {
            check(config(scope, ["command": malformed]), scope, accept: false, label: "\(scope) malformed value")
        }
        for malformed in [NSNull(), false, [], ["192.0.2.1"], "192.0.2.1"] as [Any] {
            check(config(scope, malformed), scope, accept: false, label: "\(scope) map shape")
        }
        var adjacent = config(scope, ["error": valid]); adjacent["command"] = "/bin/sh"
        check(adjacent, scope, accept: false, label: "\(scope) command beside DNS table")
    }
    for scope in ["mihomo-hosts", "xray-hosts"] {
        check(config(scope, ["error": "alias.example", "+.example": ["192.0.2.42"]]), scope, accept: true, label: "hostname alias")
        check(config(scope, ["error": ["alias.example", "192.0.2.42"]]), scope, accept: false, label: "mixed aliases and IPs")
    }
    check(config("singbox-predefined", ["error": ["alias.example"]]), "singbox-predefined", accept: false, label: "hosts server takes IPs only")
    check(config("singbox-predefined", ["error": "192.0.2.42"]), "singbox-predefined", accept: false, label: "hosts server takes IP arrays")
    for resolver in ["system", "system://", "192.0.2.53", "192.0.2.53:5353", "2001:db8::53", "tcp://[2001:db8::53]:53#DIRECT", "https://dns.example/dns-query#DIRECT", "https://dns.example/dns-query#Proxy%20Group", "tls://dns.example:853", "quic://dns.example", "dhcp://en0", "rcode://name_error"] {
        check(config("mihomo-policy", ["path": resolver]), "mihomo-policy", accept: true, label: resolver)
    }
    for resolver in ["file://dns.example/etc/hosts", "unix:///tmp/dns.sock", "tcp://dns.example/etc/hosts", "https:///etc/hosts", "https://dns.example/%00", "tcp://dns.example:70000", "rcode://not_a_code"] {
        check(config("mihomo-policy", ["path": resolver]), "mihomo-policy", accept: false, label: "invalid resolver")
    }
    // Same-named objects outside the exact schema location receive no exception.
    for scope in scopes {
        var wrong = config(scope, [:])
        wrong["nested"] = ["hosts": ["command": "192.0.2.42"], "nameserver-policy": ["path": "https://dns.example/dns-query"]]
        check(wrong, scope, accept: false, label: "nested fake DNS table")
    }
    var wrong = config("singbox-predefined", [:])
    wrong["dns"] = ["servers": [["type": "local", "predefined": ["command": ["192.0.2.42"]]]]]
    check(wrong, "singbox-predefined", accept: false, label: "predefined on non-hosts server")
    wrong["dns"] = ["servers": [[["type": "hosts", "predefined": ["command": ["192.0.2.42"]]]]]]
    check(wrong, "singbox-predefined", accept: false, label: "hosts server inside nested array")
    wrong["outbounds"] = [[["type": "xray", "xray": ["dns": ["hosts": ["command": "192.0.2.42"]]]]]]
    wrong.removeValue(forKey: "dns")
    check(wrong, "xray-hosts", accept: false, label: "Xray inside nested array")
    wrong["outbounds"] = ["xray": [["dns": ["hosts": ["command": "192.0.2.42"]]]]]
    check(wrong, "xray-hosts", accept: false, label: "dictionary/array swapped at Xray scope")
    wrong["outbounds"] = [["type": "direct", "xray": ["dns": ["hosts": ["command": "192.0.2.42"]]]]]
    check(wrong, "xray-hosts", accept: false, label: "Xray options on another outbound type")
    return checks
}
