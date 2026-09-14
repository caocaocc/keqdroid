import Foundation
import CryptoKit
import CNetworkXPC
import Darwin

public final class CoreProcess {
    public let name: String
    public let pid: pid_t
    public let startTime: UInt64
    public let executable: String
    private var outputFD: Int32
    private var gateFD: Int32
    private var exitStatus: Int32?
    private(set) public var log = Data()

    init(name: String, executable: URL, arguments: [String], environment: [String: String], directory: URL, uid: uid_t, gid: gid_t) throws {
        self.name = name; self.executable = executable.path
        var output: Int32 = -1, gate: Int32 = -1
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        let argvPointers: [UnsafePointer<CChar>?] = argv.map { value in value.map { UnsafePointer<CChar>($0) } } + [nil]
        let envPointers: [UnsafePointer<CChar>?] = env.map { value in value.map { UnsafePointer<CChar>($0) } } + [nil]
        pid = argvPointers.withUnsafeBufferPointer { args in
            envPointers.withUnsafeBufferPointer { env in
                keq_spawn_core(executable.path, args.baseAddress, env.baseAddress, directory.path, uid, gid, &output, &gate)
            }
        }
        guard pid > 0 else { throw ServiceFailure("coreStartFailed", "Cannot launch \(name): \(errno)") }
        outputFD = output; gateFD = gate; startTime = keq_process_start_time(pid)
        guard startTime != 0 else {
            close(gateFD); gateFD = -1
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0; _ = waitpid(pid, &status, 0)
            throw ServiceFailure("coreStartFailed", "Cannot establish the child process identity for crash recovery.")
        }
    }
    deinit { if outputFD >= 0 { close(outputFD) }; if gateFD >= 0 { close(gateFD) } }
    /// The caller must persist the child identity before permitting exec.
    public func releaseStartGate() throws {
        guard gateFD >= 0 else { return }
        var ready: UInt8 = 1
        let result = Darwin.write(gateFD, &ready, 1)
        close(gateFD); gateFD = -1
        guard result == 1 else { throw ServiceFailure("coreStartFailed", "Core exited before configuration was committed.") }
    }
    public var journal: [String: Any] { ["name": name, "pid": Int(pid), "startTime": startTime, "executable": executable] }
    public func collectOutput(maximumReads: Int = .max) {
        CoreOutputReader.drain(outputFD, maximumReads: maximumReads) { data in
            log.append(data)
            if log.count > 64 * 1024 { log.removeFirst(log.count - 64 * 1024) }
        }
    }
    public var isAlive: Bool {
        if exitStatus != nil { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { exitStatus = status; return false }
        return true
    }
    public func stop() throws {
        if gateFD >= 0 { close(gateFD); gateFD = -1 }
        if isAlive {
            // Child creates its own session before exec; target only that group.
            if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
            let deadline = NetworkClockSample.capture().continuous + 4
            while isAlive && NetworkClockSample.capture().continuous < deadline { collectOutput(maximumReads: 8); Thread.sleep(forTimeInterval: 0.05) }
            if isAlive {
                if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
                let killDeadline = NetworkClockSample.capture().continuous + 2
                while isAlive && NetworkClockSample.capture().continuous < killDeadline { collectOutput(maximumReads: 8); Thread.sleep(forTimeInterval: 0.05) }
                guard !isAlive else { throw ServiceFailure("recoveryFailed", "The core process could not be stopped.") }
            }
        }
        collectOutput(maximumReads: 8)
    }
}

public final class CoreRuntime {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func executable(named name: String) throws -> URL {
        guard ["keqrnel", "mihomo"].contains(name) else { throw ServiceFailure("unsupportedCore", "Unsupported core executable.") }
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        let path = directory.appendingPathComponent(name)
        try SecureFiles.requireRootOwned(root, directory: true)
        try SecureFiles.requireRootOwned(directory, directory: true)
        try SecureFiles.requireRootOwned(path, directory: false)
        let manifest = try SecureFiles.loadJSON(root.appendingPathComponent("core-manifest.json"))
        guard let item = manifest[name] as? [String: Any], let expected = item["sha256"] as? String else { throw ServiceFailure("coreVerificationFailed", "Installed core manifest is incomplete.") }
        let actual = SHA256.hash(data: try Data(contentsOf: path, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased(), keq_validate_code(path.path, nil, 0) == 0 else { throw ServiceFailure("coreVerificationFailed", "The installed \(name) executable failed integrity validation. Reinstall KEQDIS.pkg.") }
        return path
    }

    public func spawn(name: String, configuration: String, directory: URL, request: SessionRequest, identity: ClientIdentity, context: NetworkContext) throws -> CoreProcess {
        let executable = try executable(named: name)
        let coreDirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: coreDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if name == "mihomo" {
            let geo = root.appendingPathComponent("geo", isDirectory: true)
            try SecureFiles.requireRootOwned(geo, directory: true)
            for filename in ["geoip.dat", "geosite.dat"] {
                let source = geo.appendingPathComponent(filename)
                try SecureFiles.requireRootOwned(source, directory: false)
                // Fixed trusted data only. Root remains owner of read-only
                // copies; the private home becomes caller-owned for Proxy so
                // Mihomo can create its own cache.db/provider cache after exec.
                try SecureFiles.write(Data(contentsOf: source, options: .mappedIfSafe), to: coreDirectory.appendingPathComponent(filename), mode: 0o644)
            }
        }
        let configurationURL = coreDirectory.appendingPathComponent("config.json")
        try SecureFiles.write(Data(configuration.utf8), to: configurationURL)
        // Proxy processes run as the authenticated user; only the utun process
        // needs root. AWG profiles use the same Mihomo path as other proxies.
        let privileged = request.mode == "tun"
        let uid: uid_t = privileged ? 0 : identity.uid
        let gid: gid_t = privileged ? 0 : identity.gid
        if !privileged {
            guard chown(configurationURL.path, uid, gid) == 0, chown(coreDirectory.path, uid, gid) == 0 else { throw ServiceFailure("storageError", "Cannot prepare private unprivileged core files.") }
        }
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": coreDirectory.path, "TMPDIR": coreDirectory.path, "LANG": "en_US.UTF-8", "XRAY_LOCATION_ASSET": root.appendingPathComponent("geo").path]
        if privileged { environment["KEQDIS_PRIVILEGED_RUNTIME"] = "1" }
        if request.mode == "tun" {
            guard !context.dnsServers.isEmpty, context.dnsServers.allSatisfy(isPhysicalDNSAddress), !context.interfaceName.hasPrefix("utun") else { throw ServiceFailure("physicalDNSUnavailable", "No trusted physical DNS context is available.") }
            environment["KEQDIS_BOOTSTRAP_DNS"] = String(data: try JSONSerialization.data(withJSONObject: context.dnsServers), encoding: .utf8)
            environment["KEQDIS_BOOTSTRAP_INTERFACE"] = context.interfaceName
        }
        let arguments: [String]
        switch name {
        case "keqrnel": arguments = ["run", "-c", configurationURL.path]
        case "mihomo": arguments = ["-d", coreDirectory.path, "-f", configurationURL.path]
        default: throw ServiceFailure("unsupportedCore", "Unsupported core executable.")
        }
        return try CoreProcess(name: name, executable: executable, arguments: arguments, environment: environment, directory: coreDirectory, uid: uid, gid: gid)
    }
}

public func networkInterfaces() -> Set<String> {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result: Set<String> = [], item = head
    while let current = item { result.insert(String(cString: current.pointee.ifa_name)); item = current.pointee.ifa_next }
    return result
}

/// IPv6 may use a different physical service from the IPv4 default route.
/// Inspect every physical interface so a secondary adapter cannot silently
/// bypass the caller's requested IPv6 protection.
public func physicalIPv6Addresses() -> [String: [String]] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return ["unavailable": []] }
    defer { freeifaddrs(head) }
    var addresses: [String: [String]] = [:], item = head
    while let current = item {
        defer { item = current.pointee.ifa_next }
        let name = String(cString: current.pointee.ifa_name)
        guard ["en", "bridge", "bond", "vlan"].contains(where: name.hasPrefix),
              let address = current.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET6 else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: buffer)
            if isPhysicalDNSAddress(value) { addresses[name, default: []].append(value) }
        }
    }
    return addresses.mapValues { $0.sorted() }
}

public func interfaceCounters(_ name: String) -> (upload: UInt64, download: UInt64)? {
    var upload: UInt64 = 0, download: UInt64 = 0
    guard keq_interface_counters(name, &upload, &download) == 1 else { return nil }
    return (upload, download)
}
