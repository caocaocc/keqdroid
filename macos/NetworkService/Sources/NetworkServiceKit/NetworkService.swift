import Foundation
import CryptoKit
import CNetworkXPC
import Darwin

public final class NetworkService {
    public let queue = DispatchQueue(label: "io.github.caocaocc.keqdroid.network-state")
    private let root: URL
    private let state: URL
    private let settings: NetworkSettings
    private let runtime: CoreRuntime
    private let packageFingerprint: String
    private var grants: [String: Any] = [:]
    private var contexts: [String: NetworkContext] = [:]
    private var timer: DispatchSourceTimer?
    private var processes: [CoreProcess] = []
    private var activeRequest: SessionRequest?
    private var activeContext: NetworkContext?
    private var owner: ClientIdentity?
    private var snapshotUID: uid_t?
    private var sessionDirectory: URL?
    private var snapshot: [String: Any] = ["status": "disconnected"]
    private var connectedAt: Date?
    private var lastContact = Date()
    private var lastMonitor = Date()
    private var recoveryPending = false

    public init(root: URL = ServicePaths.root, clientRequirement: String) throws {
        self.root = root; state = root.appendingPathComponent("state", isDirectory: true)
        settings = NetworkSettings(stateDirectory: state); runtime = CoreRuntime(root: root)
        packageFingerprint = SHA256.hash(data: Data(clientRequirement.utf8)).map { String(format: "%02x", $0) }.joined()
        try SecureFiles.requireRootOwned(root, directory: true)
        for (name, mode) in [("state", 0o700), ("sessions", 0o711)] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: mode]) }
            try SecureFiles.requireRootOwned(directory, directory: true)
        }
        // Journal recovery always precedes stopping an orphaned TUN process.
        try settings.restore()
        try Self.recoverChildren(root: root, state: state)
        let grantURL = state.appendingPathComponent("authorized-users.json")
        if FileManager.default.fileExists(atPath: grantURL.path) { grants = try SecureFiles.loadJSON(grantURL) }
        let authorizationStatus = keq_authorization_check_right()
        guard authorizationStatus == 0 else { throw ServiceFailure("authorizationUnavailable", "Cannot access the system administrator authorization right: \(authorizationStatus)") }
    }

    /// Package lifecycle recovery; no service registration or authorization setup.
    public static func recoverInstallation(root: URL = ServicePaths.root) throws {
        try SecureFiles.requireRootOwned(root, directory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        guard FileManager.default.fileExists(atPath: state.path) else { return }
        try SecureFiles.requireRootOwned(state, directory: true)
        try NetworkSettings(stateDirectory: state).restore()
        try recoverChildren(root: root, state: state)
    }

    public func startMonitoring() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.monitor() }
        timer = source; source.resume()
    }

    public func submit(json: String, identity: ClientIdentity, completion: @escaping (String) -> Void) {
        queue.async {
            let envelope: [String: Any]
            do {
                guard let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let method = message["method"] as? String else { throw ServiceFailure("invalidRequest", "Invalid request envelope.") }
                let result = try self.handle(method: method, arguments: message["arguments"] as? [String: Any] ?? [:], identity: identity)
                envelope = ["ok": true, "result": result]
            } catch {
                let failure = error as? ServiceFailure ?? ServiceFailure("serviceError", error.localizedDescription)
                envelope = ["ok": false, "error": ["code": failure.code, "message": failure.message]]
            }
            let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data("{}".utf8)
            completion(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    public func shutdown(completion: @escaping () -> Void) {
        queue.async {
            do { try self.stop() } catch { fputs("KEQDIS recovery requires attention: \(error.localizedDescription)\n", stderr) }
            completion()
        }
    }

    private func isAuthorized(_ uid: uid_t) -> Bool {
        guard uid >= 500, let grant = grants[String(uid)] as? [String: Any] else { return false }
        return grant["packageFingerprint"] as? String == packageFingerprint
    }
    private func serviceStatus(_ uid: uid_t) -> [String: Any] {
        ["installed": true, "authorized": isAuthorized(uid), "protocolVersion": ServicePaths.protocolVersion, "version": ServicePaths.version, "busy": owner != nil && owner?.uid != uid, "recoveryRequired": recoveryPending]
    }
    private func handle(method: String, arguments: [String: Any], identity: ClientIdentity) throws -> [String: Any] {
        try SecureFiles.requireRootOwned(root, directory: true)
        try SecureFiles.requireRootOwned(state, directory: true)
        if method == "clientDisconnected" {
            if owner?.connectionID == identity.connectionID { try stop() }
            return [:]
        }
        if method == "getServiceStatus" { return serviceStatus(identity.uid) }
        if method == "authorize" {
            guard identity.uid >= 500, let encoded = arguments["authorization"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { throw ServiceFailure("authorizationDenied", "A macOS administrator authorization is required.") }
            let result = bytes.withUnsafeBytes { keq_authorization_validate($0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
            guard result == 0 else { throw ServiceFailure("authorizationDenied", "Administrator authorization was not valid (\(result)).") }
            grants[String(identity.uid)] = ["packageFingerprint": packageFingerprint, "version": ServicePaths.version, "grantedAt": Date().timeIntervalSince1970]
            try SecureFiles.writeJSON(grants, to: state.appendingPathComponent("authorized-users.json"))
            return serviceStatus(identity.uid)
        }
        guard isAuthorized(identity.uid) else { throw ServiceFailure("authorizationRequired", "Authorize network control for this macOS account first.") }
        if let owner, owner.uid != identity.uid { throw ServiceFailure("busy", "Another macOS account owns the active network session.") }
        if owner?.connectionID == identity.connectionID { lastContact = Date() }
        switch method {
        case "prepareNetworkContext":
            guard activeRequest == nil else { throw ServiceFailure("busy", "Disconnect before preparing a new physical network context.") }
            try requireRecovered()
            contexts = contexts.filter { Date().timeIntervalSince($0.value.created) < 60 }
            let context = try settings.prepare(uid: identity.uid, forTUN: true)
            contexts[context.id] = context
            return context.dictionary
        case "startSession":
            guard activeRequest == nil else { throw ServiceFailure("busy", "A network session is already active.") }
            try requireRecovered()
            return try start(SessionRequest(arguments: arguments), identity: identity)
        case "stopSession":
            if let requested = arguments["sessionId"] as? String, let activeRequest, requested != activeRequest.id { throw ServiceFailure("sessionMismatch", "The requested session no longer owns the connection.") }
            try stop(); snapshot = ["status": "disconnected"]
            return snapshot
        case "getSession":
            if owner != nil && owner?.connectionID != identity.connectionID { throw ServiceFailure("busy", "Another application instance owns this network session.") }
            if let snapshotUID, snapshotUID != identity.uid { return ["status": "disconnected"] }
            updateSnapshot(); return snapshot
        default: throw ServiceFailure("unknownMethod", "Unknown network service method.")
        }
    }

    private func start(_ request: SessionRequest, identity: ClientIdentity) throws -> [String: Any] {
        for port in [request.socksPort, request.httpPort, request.apiPort] + (request.infoPort.map { [$0] } ?? []) {
            guard keq_port_available(UInt16(port)) == 1 else { throw ServiceFailure("portUnavailable", "Local port \(port) is already in use.") }
        }
        let context: NetworkContext
        if request.mode == "tun" {
            guard let identifier = request.contextID, let prepared = contexts.removeValue(forKey: identifier), prepared.uid == identity.uid,
                  Date().timeIntervalSince(prepared.created) < 60, !prepared.dnsServers.isEmpty, !settings.physicalNetworkChanged(prepared) else { throw ServiceFailure("staleNetworkContext", "The physical network changed. Prepare a new DNS context before connecting.") }
            context = prepared
            try validateContext(request, context: context)
            try IPv4RouteSnapshot.capture().validateBeforeStarting(mode: request.mode)
        } else { context = try settings.prepare(uid: identity.uid) }
        owner = identity; snapshotUID = identity.uid; activeRequest = request; activeContext = context; lastContact = Date()
        snapshot = ["sessionId": request.id, "status": "connecting", "connectionMode": request.mode, "core": request.core]
        let before = networkInterfaces()
        do {
            let directory = root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o711])
            sessionDirectory = directory
            try persistSession()
            let order = request.core == "awg" ? (request.mode == "tun" ? ["wireproxy", "keqrnel"] : ["wireproxy"]) : [request.core]
            for name in order {
                // AWG's upstream may take seconds to start. Recheck before the
                // actual TUN process can replace an existing broad route.
                if request.mode == "tun" && name != "wireproxy" { try IPv4RouteSnapshot.capture().validateBeforeStarting(mode: request.mode) }
                guard let config = request.configurations[name] else { throw ServiceFailure("invalidConfiguration", "Missing core configuration.") }
                let process = try runtime.spawn(name: name, configuration: config, directory: directory, request: request, identity: identity, context: context)
                processes.append(process)
                try persistSession()
                try process.releaseStartGate()
                if name == "wireproxy" { try waitUntilReady(timeout: 15) { keq_socket_ready("127.0.0.1", UInt16(request.socksPort), 100) == 1 && keq_socket_ready("127.0.0.1", UInt16(request.httpPort), 100) == 1 } }
            }
            try waitUntilReady(timeout: 20) {
                let portsReady = keq_socket_ready("127.0.0.1", UInt16(request.socksPort), 100) == 1 && keq_socket_ready("127.0.0.1", UInt16(request.httpPort), 100) == 1
                let apiReady = request.core == "awg" && request.mode == "proxy" ? true : keq_socket_ready("127.0.0.1", UInt16(request.apiPort), 100) == 1
                return portsReady && apiReady
            }
            if request.mode == "tun" {
                var interface: String?
                try waitUntilReady(timeout: 8) {
                    let candidates = networkInterfaces().subtracting(before).filter { $0.hasPrefix("utun") }
                    guard candidates.count == 1, let candidate = candidates.first else { return false }
                    interface = candidate
                    return IPv4RouteSnapshot.capture().usesTunnel(candidate)
                }
                snapshot["interfaceName"] = interface
                if request.blockIpv6Leak && context.hasIPv6 {
                    guard let interface else { throw ServiceFailure("ipv6ProtectionUnavailable", "The IPv6 tunnel interface is missing.") }
                    // Cover both halves of ::/0; the second address is only a
                    // routing-table lookup, not an emitted network packet.
                    // A missing IPv6 route is a failure, never a warning.
                    guard keq_ipv6_route_uses_interface("2001:4860:4860::8888", interface) == 1,
                          keq_ipv6_route_uses_interface("9000::1", interface) == 1 else {
                        throw ServiceFailure("ipv6ProtectionUnavailable", "IPv6 traffic is not fully routed into the managed tunnel. Connection refused to prevent an IPv6 leak.")
                    }
                }
                guard let dns = request.dnsAddress else { throw ServiceFailure("invalidDNS", "TUN DNS address is missing.") }
                try waitUntilReady(timeout: 8) {
                    keq_dns_ready(dns, 53, 0, 500) == 1 && keq_dns_ready(dns, 53, 1, 500) == 1
                }
                guard let interface, IPv4RouteSnapshot.capture().usesTunnel(interface) else {
                    throw ServiceFailure("ipv4RoutesUnavailable", "IPv4 traffic is not fully routed into the managed tunnel.")
                }
            }
            // Never publish system proxy/DNS until processes, ports, utun, and
            // both DNS transports are working.
            try settings.apply(context: context, proxyPorts: request.systemProxy && request.mode == "proxy" ? (request.socksPort, request.httpPort) : nil, dnsAddress: request.mode == "tun" ? request.dnsAddress : nil)
            connectedAt = Date(); lastContact = Date(); lastMonitor = Date(); snapshot["status"] = "connected"
            try persistSession(); updateSnapshot()
            return snapshot
        } catch {
            let failure = error
            do { try stop() } catch { snapshot["recoveryError"] = error.localizedDescription }
            snapshot["status"] = "error"; snapshot["error"] = failure.localizedDescription
            snapshot["errorCode"] = (failure as? ServiceFailure)?.code ?? "startFailed"
            throw failure
        }
    }

    private func validateContext(_ request: SessionRequest, context: NetworkContext) throws {
        try ConfigPolicy.validateIPv6Protection(configurations: request.configurations, core: request.core, required: request.blockIpv6Leak && context.hasIPv6)
        if let text = request.configurations["keqrnel"], let config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let route = config["route"] as? [String: Any]
            guard route?["default_interface"] as? String == context.interfaceName else { throw ServiceFailure("unsafeConfiguration", "Core bootstrap interface differs from the prepared physical network.") }
        }
        if let text = request.configurations["mihomo"], let config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            guard config["interface-name"] as? String == context.interfaceName else { throw ServiceFailure("unsafeConfiguration", "Mihomo bootstrap interface differs from the physical network.") }
            let dns = config["dns"] as? [String: Any] ?? [:]
            let range = dns["fake-ip-range"] as? String ?? "198.18.0.1/16"
            let parts = range.split(separator: "/")
            let bytes = parts.first?.split(separator: ".").compactMap { Int($0) } ?? []
            guard parts.count == 2, bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }), bytes[3] < 254,
                  let prefix = Int(parts[1]), (1...30).contains(prefix),
                  (bytes[0] == 10 && prefix >= 8 || bytes[0] == 172 && (16...31).contains(bytes[1]) && prefix >= 12 || bytes[0] == 192 && bytes[1] == 168 && prefix >= 16 || bytes[0] == 198 && [18, 19].contains(bytes[1]) && prefix >= 15),
                  request.dnsAddress == "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3] + 1)", !context.dnsServers.contains(request.dnsAddress!) else { throw ServiceFailure("unsafeConfiguration", "Mihomo DNS must match its private fake-IP subnet and differ from physical DNS.") }
        }
    }

    private func waitUntilReady(timeout: TimeInterval, predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for process in processes {
                process.collectOutput()
                guard process.isAlive else { throw ServiceFailure("coreExited", "\(process.name) exited during startup. \(String(decoding: process.log.suffix(4096), as: UTF8.self))") }
            }
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw ServiceFailure("readinessTimeout", "Core, tunnel, or TCP/UDP DNS readiness timed out.")
    }

    private func persistSession() throws {
        try SecureFiles.writeJSON(["processes": processes.map(\.journal), "directory": sessionDirectory?.lastPathComponent ?? ""], to: state.appendingPathComponent("session-journal.json"))
    }
    private func requireRecovered() throws {
        let files = ["network-journal.json", "session-journal.json"]
        guard !recoveryPending, !files.contains(where: { FileManager.default.fileExists(atPath: state.appendingPathComponent($0).path) }) else {
            recoveryPending = true
            throw ServiceFailure("recoveryRequired", "Previous network state has not been recovered. Disconnect to retry recovery before starting another session.")
        }
    }
    private static func recoverChildren(root: URL, state: URL) throws {
        let journal = state.appendingPathComponent("session-journal.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let document = try SessionRecoveryJournal(dictionary: SecureFiles.loadJSON(journal), root: root)
        for record in document.processes {
            let path = record.executable, pid = record.pid, time = record.startTime
            if keq_process_matches(pid, time, path) == 1 {
                kill(-pid, SIGTERM)
                let deadline = Date().addingTimeInterval(4)
                while keq_process_matches(pid, time, path) == 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if keq_process_matches(pid, time, path) == 1 {
                    kill(-pid, SIGKILL)
                    let killDeadline = Date().addingTimeInterval(2)
                    while keq_process_matches(pid, time, path) == 1 && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
                    guard keq_process_matches(pid, time, path) == 0 else { throw ServiceFailure("recoveryFailed", "An old core process could not be stopped.") }
                }
            }
        }
        let directory = root.appendingPathComponent("sessions").appendingPathComponent(document.directory)
        guard keq_remove_tree(directory.path) == 0 else { throw ServiceFailure("recoveryFailed", "Cannot remove the old private session directory.") }
        try FileManager.default.removeItem(at: journal)
    }

    private func stop() throws {
        if activeRequest == nil && recoveryPending {
            try Self.recoverInstallation(root: root)
            recoveryPending = false
            snapshot.removeValue(forKey: "recoveryError")
            return
        }
        snapshot["status"] = "disconnecting"
        // If recovery fails, retain the journal and report it, but still stop the
        // service's processes. Never claim network settings were restored.
        var recoveryError: Error?
        do { try settings.restore() } catch { recoveryError = error }
        for process in processes.reversed() {
            do { try process.stop() } catch { recoveryError = recoveryError ?? error }
        }
        let logs = processes.map { "[\($0.name)]\n\(String(decoding: $0.log, as: UTF8.self))" }.joined(separator: "\n")
        processes.removeAll()
        if let directory = sessionDirectory, keq_remove_tree(directory.path) != 0 { recoveryError = recoveryError ?? ServiceFailure("recoveryFailed", "Cannot remove the private session directory.") }
        // Keep both journals until every cleanup step succeeds. A failed
        // restoration must not be overwritten by the next session.
        if recoveryError == nil {
            let journal = state.appendingPathComponent("session-journal.json")
            if FileManager.default.fileExists(atPath: journal.path) {
                do { try FileManager.default.removeItem(at: journal) } catch { recoveryError = error }
            }
        }
        recoveryPending = recoveryError != nil
        owner = nil; activeRequest = nil; activeContext = nil; sessionDirectory = nil; connectedAt = nil
        snapshot.removeValue(forKey: "networkContext")
        snapshot["status"] = recoveryError == nil ? "disconnected" : "error"
        snapshot["pids"] = [:] as [String: Int]; snapshot.removeValue(forKey: "apiSecret")
        if !logs.isEmpty { snapshot["log"] = String(logs.suffix(64 * 1024)) }
        if let recoveryError { snapshot["recoveryError"] = recoveryError.localizedDescription; throw recoveryError }
    }

    private func updateSnapshot() {
        for process in processes { process.collectOutput() }
        snapshot["pids"] = Dictionary(uniqueKeysWithValues: processes.filter(\.isAlive).map { ($0.name, Int($0.pid)) })
        if let request = activeRequest {
            snapshot["apiPort"] = request.apiPort; snapshot["apiSecret"] = request.apiSecret; snapshot["wireproxyInfoPort"] = request.infoPort
            if request.mode == "tun" { snapshot["networkContext"] = activeContext?.dictionary }
        }
        if let started = connectedAt { snapshot["durationSeconds"] = Int(Date().timeIntervalSince(started)) }
        if let name = snapshot["interfaceName"] as? String, let counters = interfaceCounters(name) {
            snapshot["totalUpload"] = counters.upload; snapshot["totalDownload"] = counters.download
        }
        if !processes.isEmpty { snapshot["log"] = String(processes.map { "[\($0.name)]\n\(String(decoding: $0.log, as: UTF8.self))" }.joined(separator: "\n").suffix(64 * 1024)) }
    }

    private func monitor() {
        let resumedFromSleep = Date().timeIntervalSince(lastMonitor) > 15
        lastMonitor = Date()
        guard activeRequest != nil else { return }
        for process in processes { process.collectOutput() }
        let exited = processes.first { !$0.isAlive }
        let networkChanged = resumedFromSleep || (activeContext.map(settings.physicalNetworkChanged) ?? false)
        let tunnelRoutesChanged = exited == nil && activeRequest?.mode == "tun" && connectedAt != nil &&
            !((snapshot["interfaceName"] as? String).map { IPv4RouteSnapshot.capture().usesTunnel($0) } ?? false)
        let expired = Date().timeIntervalSince(lastContact) > 30
        if exited != nil || networkChanged || tunnelRoutesChanged || expired {
            let reason = tunnelRoutesChanged ? "IPv4 routes no longer belong to this tunnel. The connection was stopped to restore network settings." : (networkChanged ? "The physical network changed. Reconnect with a fresh DNS context." : (expired ? "The application connection expired." : "\(exited!.name) exited unexpectedly."))
            do { try stop() } catch { snapshot["recoveryError"] = error.localizedDescription }
            snapshot["status"] = "error"; snapshot["error"] = reason
            snapshot["errorCode"] = tunnelRoutesChanged ? "vpnRouteConflict" : (networkChanged ? "network_changed" : (expired ? "clientDisconnected" : "coreExited"))
            snapshot["requiresReconnect"] = networkChanged
        }
    }
}
