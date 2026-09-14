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
    private var appliedFields: (serviceIDs: [String], fields: [String: [String: Any]])?
    public init(stateDirectory: URL) { journalURL = stateDirectory.appendingPathComponent("network-journal.json") }

    public func prepare(uid: uid_t, forTUN: Bool = false) throws -> NetworkContext {
        let availability = networkStatus()
        let mode = forTUN ? availability.tun : availability.proxy
        guard mode.state == "ready", let semantic = availability.semantic else { throw ServiceFailure(mode.reason, mode.message) }
        let primary = semantic.interface, primaryService = semantic.service
        if forTUN { try IPv4RouteSnapshot.capture().validateBeforeStarting(mode: "tun") }
        let preferences = try preferences()
        guard let current = SCNetworkSetCopyCurrent(preferences), let services = SCNetworkSetCopyServices(current) as? [SCNetworkService] else {
            throw ServiceFailure("networkSettingsUnavailable", "Cannot read current network services.")
        }
        let serviceIDs = services.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service), let device = SCNetworkInterfaceGetBSDName(interface) as String? else { return false }
            return device.hasPrefix("en") || device.hasPrefix("bridge") || device.hasPrefix("bond") || device.hasPrefix("vlan")
        }.compactMap { SCNetworkServiceGetServiceID($0) as String? }
        return NetworkContext(id: UUID().uuidString, interfaceName: primary, dnsServers: semantic.dns, serviceIDs: serviceIDs, hasIPv6: semantic.hasIPv6, created: Date(), uid: uid, primaryServiceID: primaryService, physicalSignature: semantic.revision)
    }

    /// A read-only summary also works when there is no active session. It never
    /// performs a DNS lookup, network probe, authorization or settings write.
    public func networkStatus(context: NetworkContext? = nil, ownTunnel: String? = nil) -> NetworkAvailability {
        let routes = IPv4RouteSnapshot.capture()
        guard let store = SCDynamicStoreCreate(nil, "KEQDIS network availability" as CFString, nil, nil) else {
            let failed = NetworkModeAvailability("blocked", "networkInspectionFailed", "Cannot inspect the system network configuration.")
            return NetworkAvailability(semantic: nil, proxy: failed, tun: failed)
        }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] ?? [:]
        guard let primary = global["PrimaryInterface"] as? String, let service = global["PrimaryService"] as? String else {
            return NetworkAvailability.evaluate(nil, routes: routes, ownTunnel: ownTunnel)
        }
        func value(_ key: String) -> [String: Any] { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:] }
        let ipv4 = value("State:/Network/Service/\(service)/IPv4")
        var ipv6 = value("State:/Network/Service/\(service)/IPv6")
        let addresses6 = physicalIPv6Addresses()
        guard addresses6["unavailable"] == nil else {
            let failed = NetworkModeAvailability("blocked", "networkInspectionFailed", "Cannot inspect physical IPv6 interfaces.")
            return NetworkAvailability(semantic: nil, proxy: failed, tun: failed)
        }
        ipv6["AvailableInterfaces"] = addresses6.keys.sorted()
        let configuredDNS = value("Setup:/Network/Service/\(service)/DNS")[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
        let currentDNS = value("State:/Network/Service/\(service)/DNS")[kSCPropNetDNSServerAddresses as String] as? [String] ?? configuredDNS
        var servers = currentDNS.filter(isPhysicalDNSAddress)
        // Our virtual DNS must not replace the saved physical bootstrap or
        // change its revision on every status poll. User edits are checked
        // separately against committed fields below.
        if let appliedDNS, currentDNS == [appliedDNS.address], let context, context.primaryServiceID == service { servers = context.dnsServers }
        var seen: Set<String> = []
        servers = servers.filter { seen.insert($0).inserted }
        let semantic = NetworkSemanticState(interface: primary, service: service, ipv4: ipv4, ipv6: ipv6,
            link: value("State:/Network/Interface/\(primary)/Link"), dns: servers, hasIPv6: !addresses6.isEmpty)
        return NetworkAvailability.evaluate(semantic, routes: routes, ownTunnel: ownTunnel)
    }

    public func physicalNetworkChanged(_ context: NetworkContext) -> Bool {
        networkStatus(context: context).semantic?.revision != context.physicalSignature
    }

    public func managedSettingsChanged() throws -> Bool {
        guard let appliedFields else { return false }
        let prefs = try preferences()
        SCPreferencesSynchronize(prefs)
        for identifier in appliedFields.serviceIDs {
            guard let service = SCNetworkServiceCopy(prefs, identifier as CFString) else { continue }
            for (kind, expected) in appliedFields.fields {
                guard let proto = SCNetworkServiceCopyProtocol(service, kind as CFString), SCNetworkProtocolGetEnabled(proto),
                      let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any],
                      expected.allSatisfy({ jsonEqual(current[$0.key], $0.value) }) else { return true }
            }
        }
        return false
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
        guard SCPreferencesLock(prefs, false) else { throw ServiceFailure("networkSettingsBusy", "Another process is editing network settings.") }
        defer { SCPreferencesUnlock(prefs) }
        var records: [[String: Any]] = []
        var pending: [(SCNetworkProtocol, [String: Any])] = []
        let plans = NetworkSettingsReadiness.managedFields(proxyPorts: proxyPorts, dnsAddress: dnsAddress)
        for identifier in context.serviceIDs {
            guard let service = SCNetworkServiceCopy(prefs, identifier as CFString) else { continue }
            for (kind, fields) in plans {
                guard let proto = SCNetworkServiceCopyProtocol(service, kind as CFString) else { throw ServiceFailure("networkProtocolUnavailable", "Network service \(identifier) has no \(kind) protocol.") }
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
        appliedFields = (context.serviceIDs, plans)
    }

    /// Reads fresh committed preferences and configd's merged default resolver /
    /// proxy dictionaries. It neither rewrites settings nor selects another DNS.
    public func verifyApplied(context: NetworkContext, proxyPorts: (socks: Int, http: Int)?, dnsAddress: String?, timeout: TimeInterval = 5) throws {
        let fields = NetworkSettingsReadiness.managedFields(proxyPorts: proxyPorts, dnsAddress: dnsAddress)
        let readiness = NetworkSettingsReadiness(primaryService: context.primaryServiceID, primaryInterface: context.interfaceName, serviceIDs: context.serviceIDs, fields: fields)
        try readiness.wait(timeout: timeout) {
            let prefs = try self.preferences()
            SCPreferencesSynchronize(prefs)
            var committed: [String: [String: Any]] = [:]
            var enabled: Set<String> = []
            for identifier in context.serviceIDs {
                guard let service = SCNetworkServiceCopy(prefs, identifier as CFString), SCNetworkServiceGetEnabled(service) else { continue }
                for kind in fields.keys {
                    guard let proto = SCNetworkServiceCopyProtocol(service, kind as CFString) else { continue }
                    let key = "\(identifier)/\(kind)"
                    committed[key] = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                    if SCNetworkProtocolGetEnabled(proto) { enabled.insert(key) }
                }
            }
            guard let store = SCDynamicStoreCreate(nil, "KEQDIS settings verification" as CFString, nil, nil),
                  let values = SCDynamicStoreCopyMultiple(store, ["State:/Network/Global/IPv4", "State:/Network/Global/DNS", "State:/Network/Global/Proxies"] as CFArray, nil) as? [String: Any] else {
                throw ServiceFailure("networkSettingsUnavailable", "Cannot read effective system network settings.")
            }
            let primary = values["State:/Network/Global/IPv4"] as? [String: Any] ?? [:]
            var effective: [String: [String: Any]] = [:]
            for kind in fields.keys { effective[kind] = values["State:/Network/Global/\(kind)"] as? [String: Any] }
            return NetworkSettingsObservation(primaryService: primary["PrimaryService"] as? String, primaryInterface: primary["PrimaryInterface"] as? String, committed: committed, enabled: enabled, effective: effective)
        }
    }

    public func restore() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { appliedDNS = nil; appliedFields = nil; return }
        let document: [String: Any]
        do { document = try SecureFiles.loadJSON(journalURL) }
        catch let failure as ServiceFailure where failure.code == "unsafeInstallation" { throw failure }
        catch { throw ServiceFailure("recoveryCorrupt", "Cannot read the protected network recovery journal.") }
        guard document["version"] as? Int == 1, let records = document["records"] as? [[String: Any]], !records.isEmpty else { throw ServiceFailure("recoveryCorrupt", "Network recovery journal is invalid.") }
        let prefs = try preferences()
        // Never block the state queue indefinitely on another preferences
        // writer. The service retries this transient failure with a budget.
        guard SCPreferencesLock(prefs, false) else { throw ServiceFailure("networkSettingsBusy", "Cannot lock network settings for recovery.") }
        defer { SCPreferencesUnlock(prefs) }
        for record in records {
            guard let identifier = record["serviceId"] as? String, let kind = record["protocol"] as? String,
                  [kSCNetworkProtocolTypeDNS as String, kSCNetworkProtocolTypeProxies as String].contains(kind),
                  record["enabledBefore"] is Bool,
                  let rawFields = record["fields"] as? [String: [String: Any]], !rawFields.isEmpty,
                  rawFields.values.allSatisfy({ Set($0.keys) == Set(["before", "applied"]) }) else { throw ServiceFailure("recoveryCorrupt", "Network recovery record is invalid.") }
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
        appliedFields = nil
    }
}
