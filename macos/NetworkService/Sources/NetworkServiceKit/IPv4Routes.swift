import CNetworkXPC
import Darwin

public struct IPv4RouteSnapshot {
    public let lowerHalf: String?
    public let upperHalf: String?

    public init(lowerHalf: String?, upperHalf: String?) {
        self.lowerHalf = lowerHalf; self.upperHalf = upperHalf
    }

    public static func interface(for address: String) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let result = name.withUnsafeMutableBufferPointer { keq_ipv4_route_interface(address, $0.baseAddress, $0.count) }
        return result == 1 ? String(cString: name) : nil
    }

    public static func capture() -> IPv4RouteSnapshot {
        // These addresses select opposite IPv4 halves. RTM_GET only reads the
        // kernel route table; neither address receives any network traffic.
        IPv4RouteSnapshot(lowerHalf: interface(for: "64.0.0.1"), upperHalf: interface(for: "192.0.2.1"))
    }

    public static func isPhysical(_ name: String) -> Bool {
        ["en", "bridge", "bond", "vlan"].contains(where: name.hasPrefix)
    }
    public func foreignTunnel(excluding ownTunnel: String? = nil) -> String? {
        [lowerHalf, upperHalf].compactMap { $0 }.first {
            $0 != ownTunnel && ["utun", "ppp", "ipsec", "tun", "tap"].contains(where: $0.hasPrefix)
        }
    }

    public func validateBeforeStarting(mode: String) throws {
        guard mode == "tun" else { return }
        guard let lowerHalf, let upperHalf else {
            throw ServiceFailure("ipv4RoutesUnavailable", "Cannot inspect both IPv4 route ranges before starting TUN.")
        }
        for name in [lowerHalf, upperHalf] {
            if ["utun", "ppp", "ipsec", "tun", "tap"].contains(where: name.hasPrefix) {
                throw ServiceFailure("vpnRouteConflict", "Another VPN routes IPv4 traffic through \(name). Disconnect that VPN before enabling TUN.")
            }
            guard ["en", "bridge", "bond", "vlan"].contains(where: name.hasPrefix) else {
                throw ServiceFailure("ipv4RoutesUnavailable", "The IPv4 network route uses unsupported interface \(name).")
            }
        }
    }

    public func usesTunnel(_ interface: String) -> Bool {
        interface.hasPrefix("utun") && lowerHalf == interface && upperHalf == interface
    }
}
