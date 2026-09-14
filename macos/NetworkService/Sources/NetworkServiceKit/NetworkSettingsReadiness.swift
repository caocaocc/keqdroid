import Foundation
import SystemConfiguration

public struct NetworkSettingsObservation {
    public let primaryService: String?
    public let primaryInterface: String?
    public let committed: [String: [String: Any]]
    public let enabled: Set<String>
    public let effective: [String: [String: Any]]
    public init(primaryService: String?, primaryInterface: String?, committed: [String: [String: Any]], enabled: Set<String>, effective: [String: [String: Any]]) {
        self.primaryService = primaryService; self.primaryInterface = primaryInterface
        self.committed = committed; self.enabled = enabled; self.effective = effective
    }
}

/// SCPreferences commit success is not proof that configd has published the
/// effective settings. A committed field changed by another writer fails at once;
/// only propagation to the effective default configuration is allowed to wait.
public struct NetworkSettingsReadiness {
    public let primaryService: String
    public let primaryInterface: String
    public let serviceIDs: [String]
    public let fields: [String: [String: Any]]
    public init(primaryService: String, primaryInterface: String, serviceIDs: [String], fields: [String: [String: Any]]) {
        self.primaryService = primaryService; self.primaryInterface = primaryInterface
        self.serviceIDs = serviceIDs; self.fields = fields
    }

    public static func managedFields(proxyPorts: (socks: Int, http: Int)?, dnsAddress: String?) -> [String: [String: Any]] {
        var fields: [String: [String: Any]] = [:]
        if let ports = proxyPorts {
            fields[kSCNetworkProtocolTypeProxies as String] = [
                kSCPropNetProxiesHTTPEnable as String: 1, kSCPropNetProxiesHTTPProxy as String: "127.0.0.1", kSCPropNetProxiesHTTPPort as String: ports.http,
                kSCPropNetProxiesHTTPSEnable as String: 1, kSCPropNetProxiesHTTPSProxy as String: "127.0.0.1", kSCPropNetProxiesHTTPSPort as String: ports.http,
                kSCPropNetProxiesSOCKSEnable as String: 1, kSCPropNetProxiesSOCKSProxy as String: "127.0.0.1", kSCPropNetProxiesSOCKSPort as String: ports.socks,
                kSCPropNetProxiesProxyAutoConfigEnable as String: 0, kSCPropNetProxiesProxyAutoDiscoveryEnable as String: 0,
            ]
        }
        if let address = dnsAddress { fields[kSCNetworkProtocolTypeDNS as String] = [kSCPropNetDNSServerAddresses as String: [address]] }
        return fields
    }

    public func wait(timeout: TimeInterval = 5, capture: () throws -> NetworkSettingsObservation,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard !fields.isEmpty else { return }
        guard timeout.isFinite, timeout >= 0, timeout <= 30, serviceIDs.contains(primaryService) else {
            throw ServiceFailure("networkSettingsUnavailable", "The current primary service cannot be verified.")
        }
        let deadline = now() + timeout
        while true {
            let value = try capture()
            guard value.primaryService == primaryService, value.primaryInterface == primaryInterface else {
                throw ServiceFailure("networkChanged", "The primary network service changed while applying settings.")
            }
            for service in serviceIDs {
                for (kind, expected) in fields {
                    let key = "\(service)/\(kind)"
                    guard value.enabled.contains(key), let current = value.committed[key],
                          expected.allSatisfy({ jsonEqual(current[$0.key], $0.value) }) else {
                        throw ServiceFailure("networkSettingsChanged", "Committed \(kind) settings changed before activation. Third-party changes will be preserved during recovery.")
                    }
                }
            }
            let effective = fields.allSatisfy { kind, expected in
                guard let current = value.effective[kind] else { return false }
                return expected.allSatisfy { key, target in
                    // configd may omit disabled auto-proxy flags in its effective
                    // dictionary. Absence here means disabled, never enabled.
                    if kind == kSCNetworkProtocolTypeProxies as String,
                       [kSCPropNetProxiesProxyAutoConfigEnable as String, kSCPropNetProxiesProxyAutoDiscoveryEnable as String].contains(key),
                       current[key] == nil, target as? Int == 0 { return true }
                    return jsonEqual(current[key], target)
                }
            }
            if effective { return }
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw ServiceFailure("networkSettingsNotEffective", "The system did not activate the requested default proxy or DNS settings before the deadline.")
            }
            sleep(min(0.05, remaining))
        }
    }
}
