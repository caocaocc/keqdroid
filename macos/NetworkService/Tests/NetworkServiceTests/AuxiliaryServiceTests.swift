import XCTest
@testable import NetworkServiceKit

final class AuxiliaryServiceTests: XCTestCase {
    private let secret = "0123456789abcdef"
    private func validate(_ extra: [String: Any], core: String = "mihomo") throws {
        var base: [String: Any] = core == "mihomo"
            ? ["external-controller": "127.0.0.1:9090", "secret": secret, "geodata-mode": true, "geo-auto-update": false]
            : ["experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]]]
        base.merge(extra) { _, value in value }
        try ConfigPolicy.validateJSON(base, core: core, mode: "proxy", ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
    }
    func testRejectsMihomoAuxiliaryListenersAndFirewall() {
        for key in ["ss-config", "vmess-config", "tuic-server", "iptables"] {
            XCTAssertThrowsError(try validate([key: ["enable": true, "port": 23456]])) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
        }
    }
    func testNTPReadsDoNotAuthorizeSystemClockChanges() {
        XCTAssertNoThrow(try validate(["ntp": ["enable": true, "write-to-system": false]]))
        XCTAssertThrowsError(try validate(["ntp": ["enable": true, "write-to-system": true]]))
    }
    func testRejectsEmbeddedXrayReverseAndRoutingWebhooks() {
        for xray in [
            ["outbounds": [["protocol": "vless", "settings": ["reverse": ["tag": "remote"]]]]],
            ["routing": ["rules": [["webhook": "https://example.test/log"]]]],
        ] as [[String: Any]] {
            XCTAssertThrowsError(try validate(["outbounds": [["type": "xray", "xray": xray]]], core: "keqrnel")) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
        }
    }
    func testFeatureNamesRemainLegalAsDNSAndProxyData() {
        XCTAssertNoThrow(try validate([
            "hosts": ["webhook": "192.0.2.1", "reverse": "192.0.2.2", "ss-config": "192.0.2.3"],
            "proxies": [["name": "tuic-server", "type": "socks5", "server": "example.test", "port": 443, "password": "iptables"]],
        ]))
        XCTAssertNoThrow(try validate(["outbounds": [["type": "xray", "xray": [
            "dns": ["hosts": ["webhook": "192.0.2.1", "reverse": "192.0.2.2"]],
            "outbounds": [["protocol": "vless", "tag": "reverse", "settings": ["address": "example.test", "port": 443, "id": "webhook"]]],
        ]]]], core: "keqrnel"))
    }
    func testRejectsXrayStructuralAliasesAndCollisions() {
        for xray in [
            ["outbounds": [["Protocol": "vless", "Settings": ["Reverse": ["tag": "remote"]]]]],
            ["outbounds": [["protocol": "vless", "settings": [:], "SETTINGS": ["reverse": ["tag": "remote"]]]]],
            ["routing": ["rules": [], "RULES": [["Webhook": ["url": "https://example.test/log"]]]]],
        ] as [[String: Any]] {
            for key in ["xray", "Xray"] {
                XCTAssertThrowsError(try validate(["outbounds": [["type": "xray", key: xray]]], core: "keqrnel")) {
                    XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
                }
            }
        }
    }
}
