import XCTest
@testable import NetworkServiceKit

final class LANPolicyTests: XCTestCase {
    private let ports: Set<Int> = [2080, 2081, 9090]
    private let secret = "0123456789abcdef"

    private func descriptor() -> [String: Any] {
        ["socksPort": 11080, "httpPort": 18080, "username": "", "password": ""]
    }

    private func configuration() -> [String: Any] {
        ["mode": "rule", "allow-lan": false, "bind-address": "127.0.0.1",
         "external-controller": "127.0.0.1:9090", "secret": secret,
         "geodata-mode": true, "geo-auto-update": false,
         "proxies": [["name": "proxy", "type": "trojan"]],
         "listeners": [
            ["name": "keq-lan-socks", "type": "socks", "listen": "0.0.0.0", "port": "11080", "udp": true, "rule": "keq-lan", "users": []],
            ["name": "keq-lan-http", "type": "http", "listen": "0.0.0.0", "port": "18080", "rule": "keq-lan", "users": []]],
         "sub-rules": ["keq-lan": LANPolicy.allowedSources.map { "SRC-IP-CIDR,\($0),proxy" } + ["MATCH,REJECT"]]]
    }

    func testLANRequiresExplicitPermissionAndDoesNotRewriteCoreConfiguration() throws {
        let lan = try LANConfiguration(arguments: descriptor(), reservedPorts: ports)
        let original = configuration()
        let copy = try LANPolicy.configurationForValidation(original, core: "mihomo", mode: "proxy", lan: lan)
        XCTAssertNil(copy["listeners"])
        XCTAssertEqual((original["listeners"] as? [[String: Any]])?.count, 2)
        XCTAssertNoThrow(try ConfigPolicy.validateJSON(original, core: "mihomo", mode: "proxy", ports: ports, apiPort: 9090, secret: secret, lan: lan))
        XCTAssertThrowsError(try ConfigPolicy.validateJSON(original, core: "mihomo", mode: "proxy", ports: ports, apiPort: 9090, secret: secret))
    }

    func testDescriptorRejectsCollisionsAmbiguousAuthenticationAndExtraOperations() {
        let changes: [[String: Any]] = [["socksPort": 2080], ["httpPort": 11080], ["socksPort": 80], ["httpPort": 65536],
            ["username": "u"], ["password": "p"], ["username": "a:b", "password": "p"],
            ["username": "u", "password": "p\n"], ["username": "u", "password": String(repeating: "中", count: 86)], ["command": "/bin/sh"]]
        for change in changes {
            var value = descriptor(); change.forEach { value[$0.key] = $0.value }
            XCTAssertThrowsError(try LANConfiguration(arguments: value, reservedPorts: ports)) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
        }
    }

    func testSourceRestrictionsAndLocalControllerCannotBeBypassed() throws {
        let lan = try LANConfiguration(arguments: descriptor(), reservedPorts: ports)
        let changes: [[String: Any]] = [["mode": "global"], ["mode": "direct"], ["allow-lan": true],
            ["external-controller": "0.0.0.0:9090"], ["skip-auth-prefixes": ["0.0.0.0/0"]],
            ["sub-rules": ["keq-lan": ["MATCH,proxy"]]],
            ["sub-rules": ["keq-lan": LANPolicy.allowedSources.map { "SRC-IP-CIDR,\($0),DIRECT" } + ["MATCH,REJECT"]]],
            ["nested": ["listeners": [["type": "mixed", "listen": "0.0.0.0"]]]]]
        for change in changes {
            var value = configuration(); change.forEach { value[$0.key] = $0.value }
            XCTAssertThrowsError(try ConfigPolicy.validateJSON(value, core: "mihomo", mode: "proxy", ports: ports, apiPort: 9090, secret: secret, lan: lan)) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
        }
    }
}
