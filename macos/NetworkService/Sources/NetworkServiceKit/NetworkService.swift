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
    private let helperEpoch = UUID().uuidString
    private var grants: [String: Any] = [:]
    private var contexts: [String: NetworkContext] = [:]
    private var timer: DispatchSourceTimer?
    private var processes: [CoreProcess] = []
    private var activeRequest: SessionRequest?
    private var activeContext: NetworkContext?
    private var owner: ClientIdentity?
    private var ownerDisconnected = false
    private var snapshotOwner: ClientIdentity?
    private var sessionDirectory: URL?
    private var tunnelInterface: TunnelInterfaceIdentity?
    private var interfacesBeforeSession: [String: UInt32] = [:]
    private var snapshot: [String: Any] = ["status": "disconnected"]
    private var connectedAt: Date?
    private var lastContact = NetworkClockSample.capture().awake
    private var lastMonitor = NetworkClockSample.capture()
    private var recoveryPending = false
    private var recoverySessionID: String?
    private var recoverySchedule = NetworkRecoverySchedule()
    private lazy var dnsDiagnostics = TUNDNSDiagnostics(stateQueue: queue)

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
        do {
            try restoreRecoveryOwner()
            try settings.restore()
            try Self.recoverChildren(root: root, state: state)
            owner = nil; ownerDisconnected = false; recoverySessionID = nil
        } catch { noteRecoveryFailure(error) }
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
        let journal = state.appendingPathComponent("session-journal.json")
        if FileManager.default.fileExists(atPath: journal.path) { _ = try loadSessionJournal(journal, root: root) }
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
                envelope = ["ok": false, "error": failure.dictionary]
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

    /// Called exclusively by the native XPC invalidation callback, never by a
    /// request envelope. A client cannot self-report this ownership fact.
    public func clientDisconnected(identity: ClientIdentity) {
        queue.async {
            guard self.owner?.uid == identity.uid && self.owner?.connectionID == identity.connectionID else { return }
            self.ownerDisconnected = true
            do {
                try SecureFiles.requireRootOwned(self.root, directory: true)
                try SecureFiles.requireRootOwned(self.state, directory: true)
                try self.stop()
            } catch {
                if !self.recoveryPending { self.noteRecoveryFailure(error) }
            }
        }
    }

    private func isAuthorized(_ uid: uid_t) -> Bool {
        guard uid >= 500, let grant = grants[String(uid)] as? [String: Any] else { return false }
        return grant["packageFingerprint"] as? String == packageFingerprint
    }
    private func serviceStatus(_ identity: ClientIdentity) -> [String: Any] {
        var result: [String: Any] = ["installed": true, "authorized": isAuthorized(identity.uid), "proxyWithoutElevation": true,
            "protocolVersion": ServicePaths.protocolVersion, "version": ServicePaths.version,
            "busy": SessionAccessPolicy.isBusy(owner: owner, caller: identity), "recoveryRequired": recoveryPending,
            "helperEpoch": helperEpoch, "networkStatus": settings.networkStatus(context: activeContext, ownTunnel: tunnelInterface?.name).dictionary]
        if recoveryPending { result["recoveryErrorCode"] = recoverySchedule.errorCode ?? "recoveryRequired" }
        return result
    }
    private func handle(method: String, arguments: [String: Any], identity: ClientIdentity) throws -> [String: Any] {
        try SecureFiles.requireRootOwned(root, directory: true)
        try SecureFiles.requireRootOwned(state, directory: true)
        if method == "getServiceStatus" { return serviceStatus(identity) }
        if method == "authorize" {
            guard identity.uid >= 500, let encoded = arguments["authorization"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { throw ServiceFailure("authorizationDenied", "A macOS administrator authorization is required.") }
            let result = bytes.withUnsafeBytes { keq_authorization_validate($0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
            guard result == 0 else { throw ServiceFailure("authorizationDenied", "Administrator authorization was not valid (\(result)).") }
            grants[String(identity.uid)] = ["packageFingerprint": packageFingerprint, "version": ServicePaths.version, "grantedAt": Date().timeIntervalSince1970]
            try SecureFiles.writeJSON(grants, to: state.appendingPathComponent("authorized-users.json"))
            return serviceStatus(identity)
        }
        try SessionAccessPolicy.validate(method: method, arguments: arguments, identity: identity, tunAuthorized: isAuthorized(identity.uid), owner: owner, activeSessionID: activeRequest?.id ?? recoverySessionID, ownerDisconnected: ownerDisconnected, recoveryPending: recoveryPending)
        if owner?.connectionID == identity.connectionID { lastContact = NetworkClockSample.capture().awake }
        switch method {
        case "prepareNetworkContext":
            guard activeRequest == nil else { throw ServiceFailure("busy", "Disconnect before preparing a new physical network context.") }
            try requireRecovered()
            contexts = contexts.filter { Date().timeIntervalSince($0.value.created) < 60 }
            let context = try settings.prepare(uid: identity.uid, forTUN: true)
            contexts[context.id] = context
            return context.dictionary
        case "startSession", "startProxySession":
            guard activeRequest == nil else { throw ServiceFailure("busy", "A network session is already active.") }
            try requireRecovered()
            let request = try SessionRequest(arguments: arguments)
            if method == "startProxySession", request.mode != "proxy" { throw ServiceFailure("invalidRequest", "A proxy request cannot start a TUN session.") }
            // Preflight failures belong to this attempt too. Do not return a
            // previous session's failure while reconciling a lost start reply.
            snapshotOwner = identity
            snapshot = ["sessionId": request.id, "connectionMode": request.mode, "status": "disconnected", "helperEpoch": helperEpoch, "recoveryRequired": false]
            do { return try start(request, identity: identity) }
            catch {
                if !recoveryPending {
                    let failure = error as? ServiceFailure ?? ServiceFailure("startFailed", error.localizedDescription)
                    snapshot["status"] = "error"; snapshot["error"] = failure.message; snapshot["errorCode"] = failure.code
                    if let stage = failure.stage { snapshot["errorStage"] = stage }
                }
                throw error
            }
        case "stopSession":
            // An idle caller may stop idempotently, but cannot erase another
            // connection's last failure after active ownership was released.
            if owner == nil && !recoveryPending {
                let stopped = SessionDiagnostics.snapshot(snapshot, owner: snapshotOwner, caller: identity, disconnected: true)
                if SessionDiagnostics.canRead(owner: snapshotOwner, caller: identity) { snapshot = stopped }
                return stopped
            }
            recoverySchedule.reset() // Explicit user retry; status polling never resets it.
            try stop()
            snapshot = SessionDiagnostics.snapshot(snapshot, owner: snapshotOwner, caller: identity, disconnected: true)
            return snapshot
        case "getSession":
            guard SessionDiagnostics.canRead(owner: snapshotOwner, caller: identity) else { return ["status": "disconnected", "helperEpoch": helperEpoch, "recoveryRequired": recoveryPending] }
            updateSnapshot()
            if activeRequest == nil && !recoveryPending { return SessionDiagnostics.snapshot(snapshot, owner: snapshotOwner, caller: identity) }
            return snapshot
        default: throw ServiceFailure("unknownMethod", "Unknown network service method.")
        }
    }

    private func start(_ request: SessionRequest, identity: ClientIdentity) throws -> [String: Any] {
        for port in request.allListenerPorts {
            let available = request.lanPorts.contains(port) ? keq_lan_port_available(UInt16(port)) : keq_port_available(UInt16(port))
            guard available == 1 else { throw ServiceFailure("portUnavailable", "Local port \(port) is already in use.") }
        }
        let context: NetworkContext
        if request.mode == "tun" {
            guard let identifier = request.contextID, let prepared = contexts.removeValue(forKey: identifier), prepared.uid == identity.uid,
                  Date().timeIntervalSince(prepared.created) < 60, !prepared.dnsServers.isEmpty, !settings.physicalNetworkChanged(prepared) else { throw ServiceFailure("staleNetworkContext", "The physical network changed. Prepare a new DNS context before connecting.") }
            context = prepared
            try validateContext(request, context: context)
            try IPv4RouteSnapshot.capture().validateBeforeStarting(mode: request.mode)
        } else { context = try settings.prepare(uid: identity.uid) }
        let before = request.mode == "tun" ? try TunnelInterfaceRecovery.capture() : [:]
        owner = identity; ownerDisconnected = false; snapshotOwner = identity; activeRequest = request; activeContext = context; lastContact = NetworkClockSample.capture().awake
        interfacesBeforeSession = before; tunnelInterface = nil
        recoverySchedule.reset()
        snapshot = ["sessionId": request.id, "status": "connecting", "connectionMode": request.mode, "core": request.core, "helperEpoch": helperEpoch, "recoveryRequired": false]
        var stage = "sessionSetup"
        do {
            let directory = root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o711])
            sessionDirectory = directory
            try persistSession()
            let name = request.core
            stage = "coreStartup"
            // Recheck immediately before a core can install broad routes.
            if request.mode == "tun" { try IPv4RouteSnapshot.capture().validateBeforeStarting(mode: request.mode) }
            guard let config = request.configurations[name] else { throw ServiceFailure("invalidConfiguration", "Missing core configuration.") }
            let process = try runtime.spawn(name: name, configuration: config, directory: directory, request: request, identity: identity, context: context)
            processes.append(process)
            try persistSession()
            try process.releaseStartGate()
            stage = "localEndpoints"
            try waitUntilReady(timeout: 20) {
                let portsReady = keq_socket_ready("127.0.0.1", UInt16(request.socksPort), 100) == 1 && keq_socket_ready("127.0.0.1", UInt16(request.httpPort), 100) == 1
                let apiReady = keq_socket_ready("127.0.0.1", UInt16(request.apiPort), 100) == 1
                return portsReady && apiReady && request.lanPorts.allSatisfy { keq_process_lan_listener(process.pid, UInt16($0)) == 1 }
            }
            if request.mode == "tun" {
                var interface: String?
                stage = "ipv4Routes"
                try waitUntilReady(timeout: 8) {
                    guard let candidate = tunnelInterface else { return false }
                    interface = candidate.name
                    return IPv4RouteSnapshot.capture().usesTunnel(candidate.name)
                }
                snapshot["interfaceName"] = interface
                if request.blockIpv6Leak && context.hasIPv6 {
                    stage = "ipv6Protection"
                    guard let interface else { throw ServiceFailure("ipv6ProtectionUnavailable", "The IPv6 tunnel interface is missing.") }
                    // Cover both halves of ::/0; the second address is only a
                    // routing-table lookup, not an emitted network packet.
                    // A missing IPv6 route is a failure, never a warning.
                    guard keq_ipv6_route_uses_interface("2001:4860:4860::8888", interface) == 1,
                          keq_ipv6_route_uses_interface("9000::1", interface) == 1 else {
                        throw ServiceFailure("ipv6ProtectionUnavailable", "IPv6 traffic is not fully routed into the managed tunnel. Connection refused to prevent an IPv6 leak.")
                    }
                }
                guard let interface, IPv4RouteSnapshot.capture().usesTunnel(interface) else {
                    throw ServiceFailure("ipv4RoutesUnavailable", "IPv4 traffic is not fully routed into the managed tunnel.")
                }
            }
            // Only local ownership/readiness gates network settings. External
            // DNS answers are diagnosed after connection, without tearing down
            // a healthy local tunnel when an upstream resolver is unreachable.
            let proxyPorts: (socks: Int, http: Int)? = request.systemProxy && request.mode == "proxy" ? (request.socksPort, request.httpPort) : nil
            let dnsAddress = request.mode == "tun" ? request.dnsAddress : nil
            stage = "applyNetworkSettings"
            try settings.apply(context: context, proxyPorts: proxyPorts, dnsAddress: dnsAddress)
            stage = "networkSettingsReadiness"
            try settings.verifyApplied(context: context, proxyPorts: proxyPorts, dnsAddress: dnsAddress)
            // Catch a core exit or user edit during configd verification before
            // publishing a connected session.
            stage = "finalReadiness"
            try waitUntilReady(timeout: 1) {
                keq_socket_ready("127.0.0.1", UInt16(request.socksPort), 100) == 1 &&
                keq_socket_ready("127.0.0.1", UInt16(request.httpPort), 100) == 1 &&
                request.lanPorts.allSatisfy { keq_process_lan_listener(process.pid, UInt16($0)) == 1 }
            }
            try settings.verifyApplied(context: context, proxyPorts: proxyPorts, dnsAddress: dnsAddress, timeout: 0)
            connectedAt = Date(); lastMonitor = NetworkClockSample.capture(); lastContact = lastMonitor.awake; snapshot["status"] = "connected"
            if let lan = request.lan {
                let addresses = settings.networkStatus(context: context, ownTunnel: tunnelInterface?.name).semantic?.ipv4["Addresses"] as? [String] ?? []
                snapshot["lan"] = ["socksPort": lan.socksPort, "httpPort": lan.httpPort, "addresses": addresses]
            }
            try persistSession(); updateSnapshot()
            if request.mode == "tun", let address = request.dnsAddress {
                dnsDiagnostics.start(sessionID: request.id, address: address) { [weak self] result in
                    guard let self, self.activeRequest?.id == result["sessionId"] as? String,
                          self.connectedAt != nil, self.snapshot["status"] as? String == "connected" else { return }
                    self.snapshot["dnsDiagnostics"] = result
                }
            }
            return snapshot
        } catch {
            let original = error as? ServiceFailure ?? ServiceFailure("startFailed", error.localizedDescription)
            let failure = ServiceFailure(original.code, original.message, stage: original.stage ?? stage)
            do { try stop() } catch { throw currentRecoveryFailure() }
            snapshot["status"] = "error"; snapshot["error"] = failure.localizedDescription
            snapshot["errorCode"] = failure.code
            snapshot["errorStage"] = failure.stage
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
        let deadline = NetworkClockSample.capture().continuous + timeout
        repeat {
            try checkStartupProcessesAndInterface()
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while NetworkClockSample.capture().continuous < deadline
        throw ServiceFailure("readinessTimeout", "Core or local tunnel readiness timed out.")
    }

    private func checkStartupProcessesAndInterface() throws {
        try recordTunnelInterfaceIfAvailable()
        for process in processes {
            // A continuously logging core must yield to startup deadlines.
            process.collectOutput(maximumReads: 8)
            guard process.isAlive else { throw ServiceFailure("coreExited", "\(process.name) exited during startup. \(String(decoding: process.log.suffix(4096), as: UTF8.self))") }
        }
    }

    private func recordTunnelInterfaceIfAvailable() throws {
        guard activeRequest?.mode == "tun", !processes.isEmpty else { return }
        let current = try TunnelInterfaceRecovery.capture()
        if let tunnelInterface {
            guard current[tunnelInterface.name] == tunnelInterface.index else {
                throw ServiceFailure("tunnelInterfaceLost", "The session's original tunnel interface has disappeared or been replaced.")
            }
            return
        }
        let candidates = current.filter { $0.key.hasPrefix("utun") && interfacesBeforeSession[$0.key] != $0.value }
        guard candidates.count == 1, let candidate = candidates.first else { return }
        tunnelInterface = try TunnelInterfaceIdentity(name: candidate.key, index: candidate.value)
        // Persist as soon as observed, including before local ports/DNS become
        // ready, so partial startup and helper crashes retain cleanup evidence.
        try persistSession()
        snapshot["interfaceName"] = candidate.key
    }

    private func persistSession() throws {
        var journal: [String: Any] = ["processes": processes.map(\.journal), "directory": sessionDirectory?.lastPathComponent ?? ""]
        if let tunnelInterface { journal["tunnelInterface"] = tunnelInterface.dictionary }
        if let owner { journal["ownerUid"] = Int(owner.uid) }
        if let activeRequest { journal["sessionId"] = activeRequest.id }
        try SecureFiles.writeJSON(journal, to: state.appendingPathComponent("session-journal.json"))
    }
    private func requireRecovered() throws {
        let files = ["network-journal.json", "session-journal.json"]
        guard !recoveryPending, !files.contains(where: { FileManager.default.fileExists(atPath: state.appendingPathComponent($0).path) }) else {
            recoveryPending = true
            throw currentRecoveryFailure()
        }
    }
    private func currentRecoveryFailure() -> ServiceFailure {
        ServiceFailure(recoverySchedule.errorCode ?? "recoveryRequired", snapshot["recoveryError"] as? String ?? "Previous network state must be recovered before starting another session.", stage: "networkRecovery")
    }
    private func noteRecoveryFailure(_ error: Error) {
        recoveryPending = true
        recoverySchedule.failed(error, now: NetworkClockSample.capture().continuous)
        snapshot["status"] = "error"; snapshot["recoveryRequired"] = true; snapshot["helperEpoch"] = helperEpoch
        snapshot["recoveryError"] = error.localizedDescription
        snapshot["error"] = error.localizedDescription
        snapshot["errorCode"] = recoverySchedule.errorCode ?? "recoveryRequired"
        snapshot["errorStage"] = "networkRecovery"
        snapshot.removeValue(forKey: "requiresReconnect")
    }
    private func restoreRecoveryOwner() throws {
        let url = state.appendingPathComponent("session-journal.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let document = try Self.loadSessionJournal(url, root: root)
        // Old packages did not persist a UID: automatic recovery remains
        // possible, but no account is allowed to claim its residual session.
        if document["ownerUid"] != nil || document["sessionId"] != nil {
            guard let uid = document["ownerUid"] as? UInt32, uid >= 500,
                  let identifier = document["sessionId"] as? String,
                  identifier.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil else {
                throw ServiceFailure("recoveryCorrupt", "Invalid recovery session owner.")
            }
            owner = ClientIdentity(uid: uid, gid: 0, connectionID: 0)
            ownerDisconnected = true; recoverySessionID = identifier
        }
    }
    private static func loadSessionJournal(_ url: URL, root: URL) throws -> [String: Any] {
        do {
            let document = try SecureFiles.loadJSON(url)
            _ = try SessionRecoveryJournal(dictionary: document, root: root)
            return document
        } catch let failure as ServiceFailure where failure.code == "unsafeInstallation" { throw failure }
        catch { throw ServiceFailure("recoveryCorrupt", "The protected session recovery journal is invalid.") }
    }
    private static func recoverChildren(root: URL, state: URL) throws {
        let journal = state.appendingPathComponent("session-journal.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let document = try SessionRecoveryJournal(dictionary: loadSessionJournal(journal, root: root), root: root)
        for record in document.processes {
            let path = record.executable, pid = record.pid, time = record.startTime
            if keq_process_matches(pid, time, path) == 1 {
                kill(-pid, SIGTERM)
                let deadline = NetworkClockSample.capture().continuous + 4
                while keq_process_matches(pid, time, path) == 1 && NetworkClockSample.capture().continuous < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if keq_process_matches(pid, time, path) == 1 {
                    kill(-pid, SIGKILL)
                    let killDeadline = NetworkClockSample.capture().continuous + 2
                    while keq_process_matches(pid, time, path) == 1 && NetworkClockSample.capture().continuous < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
                    guard keq_process_matches(pid, time, path) == 0 else { throw ServiceFailure("recoveryFailed", "An old core process could not be stopped.") }
                }
            }
        }
        try TunnelInterfaceRecovery.waitUntilRemoved(document.tunnelInterface)
        let directory = root.appendingPathComponent("sessions").appendingPathComponent(document.directory)
        guard keq_remove_tree(directory.path) == 0 else { throw ServiceFailure("recoveryFailed", "Cannot remove the old private session directory.") }
        try FileManager.default.removeItem(at: journal)
    }

    private func stop() throws {
        dnsDiagnostics.cancel()
        snapshot.removeValue(forKey: "dnsDiagnostics")
        snapshot.removeValue(forKey: "lan")
        if activeRequest == nil && recoveryPending {
            do {
                try Self.recoverInstallation(root: root)
                try settings.restore() // Also release this instance's in-memory ownership.
            }
            catch { noteRecoveryFailure(error); throw currentRecoveryFailure() }
            recoveryPending = false
            recoverySchedule.reset()
            owner = nil; ownerDisconnected = false; recoverySessionID = nil
            snapshot.removeValue(forKey: "recoveryError")
            for key in ["error", "errorCode", "errorStage"] { snapshot.removeValue(forKey: key) }
            snapshot["recoveryRequired"] = false; snapshot["status"] = "disconnected"
            return
        }
        snapshot["status"] = "disconnecting"
        // If recovery fails, retain the journal and report it, but still stop the
        // service's processes. Never claim network settings were restored.
        var recoveryError: Error?
        // A core may have created its utun just before another startup step
        // failed. Capture that identity before stopping its process.
        if tunnelInterface == nil {
            do { try recordTunnelInterfaceIfAvailable() } catch { recoveryError = error }
        }
        do { try settings.restore() } catch { recoveryError = NetworkRecoverySchedule.preferredFailure(recoveryError, error) }
        for process in processes.reversed() {
            do { try process.stop() } catch { recoveryError = NetworkRecoverySchedule.preferredFailure(recoveryError, error) }
        }
        do { try TunnelInterfaceRecovery.waitUntilRemoved(tunnelInterface) } catch { recoveryError = NetworkRecoverySchedule.preferredFailure(recoveryError, error) }
        let logs = processes.map { "[\($0.name)]\n\(String(decoding: $0.log, as: UTF8.self))" }.joined(separator: "\n")
        processes.removeAll()
        if recoveryError == nil, let directory = sessionDirectory, keq_remove_tree(directory.path) != 0 {
            recoveryError = ServiceFailure("recoveryFailed", "Cannot remove the private session directory.")
        }
        // Keep both journals until every cleanup step succeeds. A failed
        // restoration must not be overwritten by the next session.
        if recoveryError == nil {
            let journal = state.appendingPathComponent("session-journal.json")
            if FileManager.default.fileExists(atPath: journal.path) {
                do { try FileManager.default.removeItem(at: journal) } catch { recoveryError = error }
            }
        }
        recoveryPending = recoveryError != nil
        // Failed recovery still belongs to the original connection. Another
        // account must not gain control merely because the core has stopped.
        recoverySessionID = recoveryPending ? activeRequest?.id : nil
        if !recoveryPending { owner = nil; ownerDisconnected = false; recoverySchedule.reset() }
        activeRequest = nil; activeContext = nil; sessionDirectory = nil; connectedAt = nil
        tunnelInterface = nil; interfacesBeforeSession = [:]
        snapshot.removeValue(forKey: "networkContext")
        snapshot["status"] = recoveryError == nil ? "disconnected" : "error"
        snapshot["recoveryRequired"] = recoveryPending
        snapshot["pids"] = [:] as [String: Int]; snapshot.removeValue(forKey: "apiSecret")
        if !logs.isEmpty { snapshot["log"] = String(logs.suffix(64 * 1024)) }
        if let recoveryError {
            noteRecoveryFailure(recoveryError)
            throw currentRecoveryFailure()
        }
    }

    private func updateSnapshot() {
        for process in processes { process.collectOutput(maximumReads: 8) }
        snapshot["pids"] = Dictionary(uniqueKeysWithValues: processes.filter(\.isAlive).map { ($0.name, Int($0.pid)) })
        if let request = activeRequest {
            snapshot["apiPort"] = request.apiPort; snapshot["apiSecret"] = request.apiSecret
            if request.mode == "tun" { snapshot["networkContext"] = activeContext?.dictionary }
        }
        if let started = connectedAt { snapshot["durationSeconds"] = Int(Date().timeIntervalSince(started)) }
        if let name = snapshot["interfaceName"] as? String, let counters = interfaceCounters(name) {
            snapshot["totalUpload"] = counters.upload; snapshot["totalDownload"] = counters.download
        }
        if !processes.isEmpty { snapshot["log"] = String(processes.map { "[\($0.name)]\n\(String(decoding: $0.log, as: UTF8.self))" }.joined(separator: "\n").suffix(64 * 1024)) }
    }

    private func monitor() {
        let clock = NetworkClockSample.capture()
        let resumedFromSleep = clock.resumed(after: lastMonitor)
        lastMonitor = clock
        if recoveryPending {
            if recoverySchedule.takeDue(now: clock.continuous) { do { try stop() } catch {} }
            return
        }
        guard activeRequest != nil else { return }
        for process in processes { process.collectOutput(maximumReads: 8) }
        let exited = processes.first { !$0.isAlive }
        let routes = IPv4RouteSnapshot.capture()
        let networkChanged = activeContext.map(settings.physicalNetworkChanged) ?? false
        let foreign = activeRequest?.mode == "tun" ? routes.foreignTunnel(excluding: tunnelInterface?.name) : nil
        var failure: ServiceFailure?
        do { if try settings.managedSettingsChanged() { failure = ServiceFailure("networkSettingsChanged", "Network settings were changed by the user or another application.") } }
        catch { failure = ServiceFailure("networkInspectionFailed", "Cannot verify ownership of the network settings.") }
        if failure == nil, let foreign { failure = ServiceFailure("vpnRouteConflict", "Another VPN owns IPv4 routes through \(foreign).") }
        if failure == nil && resumedFromSleep { failure = ServiceFailure("systemWake", "The system resumed from sleep. Refresh the physical network context.") }
        if failure == nil && networkChanged { failure = ServiceFailure("network_changed", "The physical network changed. Refresh the DNS context when it is available.") }
        if failure == nil, let exited { failure = ServiceFailure("coreExited", "\(exited.name) exited unexpectedly.") }
        if failure == nil && activeRequest?.mode == "tun" && connectedAt != nil && !(tunnelInterface.map { routes.usesTunnel($0.name) } ?? false) {
            failure = ServiceFailure("ipv4RoutesUnavailable", "The managed IPv4 routes are no longer available.")
        }
        if failure == nil && clock.awake - lastContact > 30 { failure = ServiceFailure("clientDisconnected", "The application connection expired.") }
        guard let failure else { return }
        do { try stop() } catch { return } // Recovery failures always take precedence.
        snapshot["status"] = "error"; snapshot["error"] = failure.message; snapshot["errorCode"] = failure.code
        snapshot["requiresReconnect"] = ["network_changed", "systemWake", "coreExited", "ipv4RoutesUnavailable"].contains(failure.code)
    }
}
