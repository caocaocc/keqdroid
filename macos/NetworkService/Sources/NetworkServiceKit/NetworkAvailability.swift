import Foundation
import CryptoKit

/// Only facts that change routing/bootstrap belong in this revision. DHCP
/// renewal times and IPv6 privacy-address rotation must not restart a session.
public struct NetworkSemanticState {
    public let interface: String
    public let service: String
    public let ipv4: [String: Any]
    public let ipv6: [String: Any]
    public let link: [String: Any]
    public let dns: [String]
    public let hasIPv6: Bool
    public init(interface: String, service: String, ipv4: [String: Any], ipv6: [String: Any], link: [String: Any], dns: [String], hasIPv6: Bool) {
        self.interface = interface; self.service = service; self.ipv4 = ipv4; self.ipv6 = ipv6; self.link = link; self.dns = dns; self.hasIPv6 = hasIPv6
    }
    public var revision: String {
        func fields(_ source: [String: Any], _ keys: [String]) -> [String: Any] {
            var result: [String: Any] = [:]
            for key in keys {
                if let values = source[key] as? [String] { result[key] = values.sorted() }
                else if let value = source[key], JSONSerialization.isValidJSONObject([value]) { result[key] = value }
            }
            return result
        }
        let object: [String: Any] = ["interface": interface, "service": service,
            "ipv4": fields(ipv4, ["Addresses", "SubnetMasks", "Router"]),
            "ipv6": fields(ipv6, ["Router", "AvailableInterfaces"]),
            "link": fields(link, ["Active"]), "dns": dns, "hasIPv6": hasIPv6]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func replacingDNS(_ values: [String]) -> NetworkSemanticState {
        NetworkSemanticState(interface: interface, service: service, ipv4: ipv4, ipv6: ipv6, link: link, dns: values, hasIPv6: hasIPv6)
    }
}

public struct NetworkModeAvailability {
    public let state: String
    public let reason: String
    public let message: String
    public init(_ state: String, _ reason: String, _ message: String) { self.state = state; self.reason = reason; self.message = message }
    public static let ready = NetworkModeAvailability("ready", "ready", "The physical network is available.")
    public var dictionary: [String: String] { ["state": state, "reason": reason, "message": message] }
}

public struct NetworkAvailability {
    public let semantic: NetworkSemanticState?
    public let proxy: NetworkModeAvailability
    public let tun: NetworkModeAvailability
    public var dictionary: [String: Any] {
        ["revision": (semantic?.revision ?? "unavailable") + ":" + proxy.reason + ":" + tun.reason,
         "proxy": proxy.dictionary, "tun": tun.dictionary]
    }
    public init(semantic: NetworkSemanticState?, proxy: NetworkModeAvailability, tun: NetworkModeAvailability) {
        self.semantic = semantic; self.proxy = proxy; self.tun = tun
    }
    public static func evaluate(_ semantic: NetworkSemanticState?, routes: IPv4RouteSnapshot, ownTunnel: String? = nil) -> NetworkAvailability {
        let conflict = routes.foreignTunnel(excluding: ownTunnel)
        let conflictState = conflict.map { NetworkModeAvailability("blocked", "vpnRouteConflict", "Another VPN routes IPv4 traffic through \($0). Disconnect that VPN before enabling TUN.") }
        guard let semantic else {
            let wait = NetworkModeAvailability("wait", "physicalNetworkUnavailable", "Waiting for a physical network connection.")
            return NetworkAvailability(semantic: nil, proxy: wait, tun: conflictState ?? wait)
        }
        guard IPv4RouteSnapshot.isPhysical(semantic.interface) else {
            let unsupported = NetworkModeAvailability("blocked", "unsupportedNetwork", "The default network does not use a supported physical interface.")
            return NetworkAvailability(semantic: semantic, proxy: unsupported, tun: conflictState ?? unsupported)
        }
        guard semantic.link["Active"] as? Bool != false, !(semantic.ipv4["Addresses"] as? [String] ?? []).isEmpty else {
            let wait = NetworkModeAvailability("wait", "physicalNetworkUnavailable", "Waiting for a physical IPv4 address.")
            return NetworkAvailability(semantic: semantic, proxy: wait, tun: conflictState ?? wait)
        }
        guard routes.lowerHalf != nil && routes.upperHalf != nil else {
            let wait = NetworkModeAvailability("wait", "ipv4RoutesUnavailable", "Waiting for physical IPv4 routes.")
            return NetworkAvailability(semantic: semantic, proxy: wait, tun: conflictState ?? wait)
        }
        var tun = conflictState ?? .ready
        if conflictState == nil {
            if [routes.lowerHalf, routes.upperHalf].compactMap({ $0 }).contains(where: { !IPv4RouteSnapshot.isPhysical($0) && $0 != ownTunnel }) {
                tun = NetworkModeAvailability("blocked", "unsupportedNetwork", "The IPv4 route uses an unsupported interface.")
            } else if semantic.dns.isEmpty {
                tun = NetworkModeAvailability("wait", "physicalDNSUnavailable", "Waiting for physical DNS servers before starting TUN.")
            }
        }
        return NetworkAvailability(semantic: semantic, proxy: .ready, tun: tun)
    }
}
