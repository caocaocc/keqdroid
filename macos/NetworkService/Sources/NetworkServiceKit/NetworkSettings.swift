import Foundation
import SystemConfiguration

public struct NetworkContext {
    public let id: String
    public let interfaceName: String
    public let dnsServers: [String]
    public let serviceIDs: [String]
    public let hasIPv6: Bool
    public let created: Date
    public let uid: uid_t
    public let primaryServiceID: String
    public let physicalSignature: String
    public var dictionary: [String: Any] {
        ["contextId": id, "interfaceName": interfaceName, "dnsServers": dnsServers, "serviceIds": serviceIDs, "hasIpv6": hasIPv6]
    }
}

public final class NetworkSettings {
    private let journalURL: URL
    private var appliedDNS: (serviceIDs: [String], address: String)?
    public init(stateDirectory: URL) { journalURL = stateDirectory.appendingPathComponent("network-journal.json") }

    public func prepare(uid: uid_t) throws -> NetworkContext {
        guard let store = SCDynamicStoreCreate(nil, "KEQDIS context" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String, ["en", "bridge", "bond", "vlan"].contains(where: primary.hasPrefix),
              let primaryService = global["PrimaryService"] as? String else {
            throw ServiceFailure("physicalNetworkUnavailable", "No physical default network is available. Disconnect another VPN and retry.")
        }
        let preferences = try preferences()
        guard let current = SCNetworkSetCopyCurrent(preferences), let services = SCNetworkSetCopyServices(current) as? [SCNetworkService] else {
            throw ServiceFailure("networkSettingsUnavailable", "Cannot read current network services.")
        }
        let serviceIDs = services.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service), let device = SCNetworkInterfaceGetBSDName(interface) as String? else { return false }
            return device.hasPrefix("en") || device.hasPrefix("bridge") || device.hasPrefix("bond") || device.hasPrefix("vlan")
        }.compactMap { SCNetworkServiceGetServiceID($0) as String? }
        let dnsState = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(primaryService)/DNS" as CFString) as? [String: Any]
        let primaryConfiguration = services.first { (SCNetworkServiceGetServiceID($0) as String?) == primaryService }
            .flatMap { SCNetworkServiceCopyProtocol($0, kSCNetworkProtocolTypeDNS) }
            .flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
        let servers = (dnsState?[kSCPropNetDNSServerAddresses as String] as? [String] ?? primaryConfiguration?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []).filter(isPhysicalDNSAddress)
        let ipv6 = physicalIPv6Addresses()
        guard ipv6["unavailable"] == nil else { throw ServiceFailure("physicalNetworkUnavailable", "Cannot inspect physical IPv6 interfaces.") }
        let hasIPv6 = !ipv6.isEmpty
        return NetworkContext(id: UUID().uuidString, interfaceName: primary, dnsServers: Array(NSOrderedSet(array: servers)) as? [String] ?? servers, serviceIDs: serviceIDs, hasIPv6: hasIPv6, created: Date(), uid: uid, primaryServiceID: primaryService, physicalSignature: physicalSignature(store: store, service: primaryService, interface: primary))
    }

    private func physicalSignature(store: SCDynamicStore, service: String, interface: String) -> String {
        let keys = ["State:/Network/Service/\(service)/IPv4", "State:/Network/Service/\(service)/IPv6", "State:/Network/Interface/\(interface)/Link", "State:/Network/Service/\(service)/DHCP"]
        func canonical(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(canonical) }
            if let values = value as? [Any] { return values.map(canonical) }
            if let data = value as? Data { return data.base64EncodedString() }
            if let date = value as? Date { return date.timeIntervalSince1970 }
            return value
        }
        let values = keys.map { canonical(SCDynamicStoreCopyValue(store, $0 as CFString) ?? NSDictionary()) } + [physicalIPv6Addresses()]
        return (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).base64EncodedString()) ?? ""
    }

    public func physicalNetworkChanged(_ context: NetworkContext) -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "KEQDIS monitor" as CFString, nil, nil) else { return true }
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any], let primary = global["PrimaryInterface"] as? String,
           !primary.hasPrefix("utun"), primary != context.interfaceName { return true }
        if let appliedDNS {
            // Check the committed user-editable fields, not effective resolver
            // state (which can lag SCPreferencesApplyChanges). A third-party
            // DNS edit must trigger fresh bootstrap and survive restoration.
            guard let prefs = try? preferences() else { return true }
            for identifier in appliedDNS.serviceIDs {
                guard let service = SCNetworkServiceCopy(prefs, identifier as CFString),
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
                      let config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any],
                      config[kSCPropNetDNSServerAddresses as String] as? [String] == [appliedDNS.address] else { return true }
            }
        } else {
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(context.primaryServiceID)/DNS" as CFString) as? [String: Any]
            if let current = dns?[kSCPropNetDNSServerAddresses as String] as? [String], current.filter(isPhysicalDNSAddress) != context.dnsServers { return true }
        }
        return physicalSignature(store: store, service: context.primaryServiceID, interface: context.interfaceName) != context.physicalSignature
    }

    private func preferences() throws -> SCPreferences {
        guard let value = SCPreferencesCreate(nil, "KEQDIS network service" as CFString, nil) else { throw ServiceFailure("networkSettingsUnavailable", "Cannot open SystemConfiguration preferences.") }
        return value
    }

    /// Journals before committing. A crash after persistence but before commit is
    /// harmless: compare-and-restore will only undo fields actually applied.
    public func apply(context: NetworkContext, proxyPorts: (socks: Int, http: Int)?, dnsAddress: String?) throws {
        if proxyPorts == nil && dnsAddress == nil { return }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, true) else { throw ServiceFailure("networkSettingsBusy", "Another process is editing network settings.") }
        defer { SCPreferencesUnlock(prefs) }
        var records: [[String: Any]] = []
        var pending: [(SCNetworkProtocol, [String: Any])] = []
        for identifier in context.serviceIDs {
            guard let service = SCNetworkServiceCopy(prefs, identifier as CFString) else { continue }
            var plans: [(CFString, [String: Any])] = []
            if let ports = proxyPorts {
                plans.append((kSCNetworkProtocolTypeProxies, [
                    kSCPropNetProxiesHTTPEnable as String: 1,
                    kSCPropNetProxiesHTTPProxy as String: "127.0.0.1",
                    kSCPropNetProxiesHTTPPort as String: ports.http,
                    kSCPropNetProxiesHTTPSEnable as String: 1,
                    kSCPropNetProxiesHTTPSProxy as String: "127.0.0.1",
                    kSCPropNetProxiesHTTPSPort as String: ports.http,
                    kSCPropNetProxiesSOCKSEnable as String: 1,
                    kSCPropNetProxiesSOCKSProxy as String: "127.0.0.1",
                    kSCPropNetProxiesSOCKSPort as String: ports.socks,
                    kSCPropNetProxiesProxyAutoConfigEnable as String: 0,
                    kSCPropNetProxiesProxyAutoDiscoveryEnable as String: 0,
                ]))
            }
            if let address = dnsAddress { plans.append((kSCNetworkProtocolTypeDNS, [kSCPropNetDNSServerAddresses as String: [address]])) }
            for (kind, fields) in plans {
                guard let proto = SCNetworkServiceCopyProtocol(service, kind) else { throw ServiceFailure("networkProtocolUnavailable", "Network service \(identifier) has no \(kind) protocol.") }
                let original = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                var changed = original
                var journal: [String: Any] = [:]
                for (key, value) in fields {
                    journal[key] = FieldChange(before: original[key], applied: value).dictionary
                    changed[key] = value
                }
                records.append(["serviceId": identifier, "protocol": kind as String, "fields": journal, "enabledBefore": SCNetworkProtocolGetEnabled(proto)])
                pending.append((proto, changed))
            }
        }
        guard !records.isEmpty else { throw ServiceFailure("networkSettingsUnavailable", "No eligible physical network services were found.") }
        try SecureFiles.writeJSON(["version": 1, "records": records], to: journalURL)
        for (proto, changed) in pending where !SCNetworkProtocolSetConfiguration(proto, changed as CFDictionary) {
            throw ServiceFailure("networkSettingsFailed", "Cannot stage the network settings change.")
        }
        for (proto, _) in pending where !SCNetworkProtocolSetEnabled(proto, true) { throw ServiceFailure("networkSettingsFailed", "Cannot enable the network protocol.") }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw ServiceFailure("networkSettingsFailed", "Cannot apply the network settings change.")
        }
        if let dnsAddress { appliedDNS = (context.serviceIDs, dnsAddress) }
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { appliedDNS = nil; return }
        let document = try SecureFiles.loadJSON(journalURL)
        guard document["version"] as? Int == 1, let records = document["records"] as? [[String: Any]], !records.isEmpty else { throw ServiceFailure("recoveryFailed", "Network recovery journal is invalid.") }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, true) else { throw ServiceFailure("networkSettingsBusy", "Cannot lock network settings for recovery.") }
        defer { SCPreferencesUnlock(prefs) }
        for record in records {
            guard let identifier = record["serviceId"] as? String, let kind = record["protocol"] as? String,
                  [kSCNetworkProtocolTypeDNS as String, kSCNetworkProtocolTypeProxies as String].contains(kind),
                  record["enabledBefore"] is Bool,
                  let rawFields = record["fields"] as? [String: [String: Any]], !rawFields.isEmpty,
                  rawFields.values.allSatisfy({ Set($0.keys) == Set(["before", "applied"]) }) else { throw ServiceFailure("recoveryFailed", "Network recovery record is invalid.") }
            guard let service = SCNetworkServiceCopy(prefs, identifier as CFString), let proto = SCNetworkServiceCopyProtocol(service, kind as CFString) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let changes = rawFields.mapValues(FieldChange.init(dictionary:))
            let result = restoreFields(current: current, changes: changes)
            guard SCNetworkProtocolSetConfiguration(proto, result as CFDictionary) else { throw ServiceFailure("recoveryFailed", "Cannot restore network service \(identifier).") }
            if let enabledBefore = record["enabledBefore"] as? Bool {
                let enabled = SCNetworkProtocolGetEnabled(proto)
                let restored = restoreProtocolEnabled(current: enabled, before: enabledBefore, fields: current, changes: changes)
                if restored != enabled, !SCNetworkProtocolSetEnabled(proto, restored) { throw ServiceFailure("recoveryFailed", "Cannot restore network protocol state.") }
            }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw ServiceFailure("recoveryFailed", "Cannot commit restored network settings.") }
        try FileManager.default.removeItem(at: journalURL)
        appliedDNS = nil
    }
}
