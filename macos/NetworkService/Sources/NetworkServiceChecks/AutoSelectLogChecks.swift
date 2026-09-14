import Foundation
import NetworkServiceKit

// Pure bytes/configuration fixtures; no child process or system network access.
func runAutoSelectLogChecks() -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: auto select logs: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    for (line, expected) in [
        ("[Info] proxy/vless/outbound: failed to find an available destination", true),
        ("[Info] transport/internet/splithttp: failed to dial", true),
        ("[Info] transport/internet/splithttp: unexpected status 502", true),
        ("[Info] transport/internet/splithttp: failed to create request", false),
        ("[TCP] dial proxy (match Match) fixture error: refused", true),
        ("[TCP] dial DIRECT (match Match) fixture error: refused", false),
        ("[TCP] dial REJECT (match Match) fixture error: refused", false),
        ("[UDP] dial proxy (match Match) fixture error: refused", false),
        ("[TCP] dial proxy (match Match) fixture", false),
        ("open connection to fixture using outbound/xray[proxy]: refused", true),
        ("open connection to fixture using outbound/direct[direct]: refused", false),
        ("open connection to fixture using outbound/block[block]: refused", false),
        ("normal output", false)
    ] { expect(CoreSessionLog.isDialFailure(line) == expected, "failure classification") }

    let failure = "2026/09/23 [Info] transport/internet/splithttp: failed to dial 本地\r\n"
    var log = CoreSessionLog(xrayThreshold: 2)
    for byte in failure.utf8 { log.append(Data([byte])) }
    expect(log.dialFailures == 1, "split UTF8 and failure counted once")
    expect(log.data.isEmpty, "info hidden at the requested warning level")
    log.append(Data("[Warning] visible\n[TCP] dial proxy (match Match) error: refused\n".utf8))
    expect(log.dialFailures == 2, "Mihomo failure included")
    expect(String(decoding: log.data, as: UTF8.self).contains("[Warning] visible"), "chosen warning remains visible")
    let oldData = log.data
    log.finish(); log.finish()
    expect(log.data == oldData && log.dialFailures == 2, "repeated snapshots/EOF never recount")
    log.append(Data("[Info] failed to find an available destination".utf8))
    expect(log.dialFailures == 2, "unterminated fragment waits for EOF")
    log.finish()
    expect(log.dialFailures == 3, "EOF counts final unterminated line")
    var all = CoreSessionLog()
    for byte in "[Info] 中文\n".utf8 { all.append(Data([byte])) }
    expect(String(decoding: all.data, as: UTF8.self) == "[Info] 中文\n", "UTF8 display preserved across chunks")
    all.append(Data(repeating: 65, count: 200_000)); all.append(Data([10]))
    expect(all.data.count <= 65536, "long lines and retained log are bounded")
    all.append(Data(failure.utf8)); all.finish()
    expect(all.dialFailures == 1, "overflow resumes at next line")
    let secret = "0123456789abcdef"
    let configuration: [String: Any] = ["inbounds": [["type": "socks", "listen": "127.0.0.1", "listen_port": 2080]], "outbounds": [["type": "direct"]], "experimental": ["clash_api": ["external_controller": "127.0.0.1:9090", "secret": secret]]]
    var request: [String: Any] = ["protocolVersion": 1, "sessionId": "log-test", "connectionMode": "proxy", "core": "keqrnel", "socksPort": 2080, "httpPort": 2081, "apiPort": 9090, "apiSecret": secret, "configurations": ["keqrnel": String(data: try! JSONSerialization.data(withJSONObject: configuration), encoding: .utf8)!]]
    expect((try? SessionRequest(arguments: request).xrayLogThreshold) == 0, "legacy request defaults to unchanged display")
    for level in 0...4 {
        request["xrayLogThreshold"] = level
        expect((try? SessionRequest(arguments: request).xrayLogThreshold) == level, "valid display level")
    }
    for invalid in [true, -1, 5, 1.5, "warning", NSNull()] as [Any] {
        request["xrayLogThreshold"] = invalid
        expect((try? SessionRequest(arguments: request)) == nil, "malformed display level rejected")
    }
    return checks
}
