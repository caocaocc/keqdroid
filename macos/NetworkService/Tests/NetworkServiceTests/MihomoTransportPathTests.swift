import XCTest
@testable import NetworkServiceKit

final class MihomoTransportPathTests: XCTestCase {
    private let secret = "0123456789abcdef"

    private func validate(_ proxies: Any, mode: String = "proxy", core: String = "mihomo") throws {
        let object: [String: Any] = ["proxies": proxies, "external-controller": "127.0.0.1:9090", "secret": secret,
            "geodata-mode": true, "geo-auto-update": false, "tun": ["enable": mode == "tun"]]
        try ConfigPolicy.validateJSON(object, core: core, mode: mode, ports: [2080, 2081, 9090], apiPort: 9090, secret: secret)
    }

    private func xhttp(_ path: Any) -> [String: Any] {
        ["type": "vless", "network": "xhttp", "xhttp-opts": ["path": path]]
    }

    func testGeneratedMihomoTransportURLPathsInProxyAndTUN() {
        for mode in ["proxy", "tun"] {
            for path in ["", "/", "/transport?test=1", "/custom%20path", "/etc/hosts", "/" + String(repeating: "a", count: 2047)] {
                XCTAssertNoThrow(try validate([xhttp(path)], mode: mode))
            }
            for type in ["vless", "vmess", "trojan"] {
                XCTAssertNoThrow(try validate([["type": type, "network": "ws", "ws-opts": ["path": "/ws", "v2ray-http-upgrade": true]]], mode: mode))
            }
            for type in ["vless", "vmess"] {
                XCTAssertNoThrow(try validate([["type": type, "network": "h2", "h2-opts": ["path": "/h2"]]], mode: mode))
                XCTAssertNoThrow(try validate([["type": type, "network": "http", "http-opts": ["path": ["/a", "/b"]]]], mode: mode))
            }
            XCTAssertNoThrow(try validate([["type": "vless", "network": "xhttp", "xhttp-opts": ["path": "/upload", "download-settings": ["path": "/download"]]]], mode: mode))
        }
    }

    func testMalformedTransportURLPathsAreRejected() {
        for path in [NSNull(), true, 1, ["/path"], ["path": "/path"], "relative", "file:///etc/hosts", "/" + String(repeating: "a", count: 2048), "/line\n", "/nul\0", "/del\u{7f}", "/encoded%00", "/encoded%0a", "/invalid%XX"] as [Any] {
            XCTAssertThrowsError(try validate([xhttp(path)])) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
            XCTAssertThrowsError(try validate([["type": "vless", "network": "http", "http-opts": ["path": [path]]]]))
            XCTAssertThrowsError(try validate([["type": "vless", "network": "xhttp", "xhttp-opts": ["download-settings": ["path": path]]]]))
        }
        XCTAssertThrowsError(try validate([["type": "vless", "network": "http", "http-opts": ["path": "/not-an-array"]]]))
    }

    func testExemptionRequiresExactProxyAndTransportScope() {
        let valid = xhttp("/transport")
        for proxies in [valid, [[valid]], ["nested": [valid]], [["nested": valid]],
            [["type": "trojan", "network": "xhttp", "xhttp-opts": ["path": "/transport"]]],
            [["type": "vless", "network": "tcp", "xhttp-opts": ["path": "/transport"]]],
            [["type": "vless", "network": "xhttp", "xhttp-opts": [["path": "/transport"]]]],
            [["type": "vless", "network": "xhttp", "xhttp-opts": ["nested": ["path": "/etc/hosts"]]]],
            [["type": "vless", "network": "xhttp", "xhttp-opts": ["download-settings": [["path": "/transport"]]]]],
            [["type": "vless", "network": "ws", "ws-opts": ["download-settings": ["path": "/transport"]]]]
        ] as [Any] {
            XCTAssertThrowsError(try validate(proxies)) {
                XCTAssertEqual(($0 as? ServiceFailure)?.code, "unsafeConfiguration")
            }
        }
        XCTAssertThrowsError(try validate([valid], core: "keqrnel"))
        for key in ["certificate-path", "command", "path"] {
            var unsafe = valid; unsafe[key] = "/etc/hosts"
            XCTAssertThrowsError(try validate([unsafe]))
        }
        var privateKey = valid
        privateKey["certificate"] = "-----BEGIN CERTIFICATE-----\nexample"
        privateKey["private-key"] = "/etc/private.pem"
        XCTAssertThrowsError(try validate([privateKey]))
    }
}
