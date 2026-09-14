import Foundation
import NetworkServiceKit
import CNetworkXPC
import Darwin

// These fixtures never touch installed components or system network settings.
func runSecureCreationChecks() -> Int {
    let directory = URL(fileURLWithPath: "/private/tmp/keqdis-umask-check-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = umask(0o077)
        defer { umask(previous) }
        let path = directory.appendingPathComponent("geo.dat")
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw ServiceFailure("test", "open failed") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & 0o777 == 0o600 else { throw ServiceFailure("test", "umask regression fixture did not reproduce masked mode") }
        guard fchmod(descriptor, 0o644) == 0, fstat(descriptor, &info) == 0, info.st_mode & 0o777 == 0o644 else { throw ServiceFailure("test", "explicit descriptor permissions failed") }
        if geteuid() != 0 {
            do { try SecureFiles.write(Data("test".utf8), to: directory.appendingPathComponent("state.json")); throw ServiceFailure("test", "user-owned secure state directory accepted") }
            catch let error as ServiceFailure where error.code == "unsafeInstallation" {}
        }
        return geteuid() == 0 ? 2 : 3
    } catch { fputs("FAIL: secure creation permissions: \(error.localizedDescription)\n", stderr); exit(1) }
}

func runPrivilegedFilePermissionChecks(uid: uid_t, gid: gid_t) -> Int {
    guard geteuid() == 0, uid >= 500, uid != uid_t.max else { fputs("Root file checks require root and an explicit non-root test UID.\n", stderr); exit(1) }
    let directory = URL(fileURLWithPath: "/private/tmp/keqdis-network-permissions-\(UUID().uuidString)", isDirectory: true)
    var checks = 0
    func require(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw ServiceFailure("test", label) }; checks += 1
    }
    func inspect(_ path: URL, owner: uid_t, mode: mode_t) throws {
        var info = stat()
        try require(lstat(path.path, &info) == 0 && info.st_uid == owner && info.st_mode & 0o777 == mode, "wrong owner/mode for \(path.lastPathComponent)")
    }
    // Use the production fork/gate/setgroups/setgid/setuid/exec path, with the
    // fixed system cat executable reading only files in this random fixture.
    func readAs(_ path: URL, childUID: uid_t, childGID: gid_t) throws -> (status: Int32, output: Data) {
        let argumentStrings: [String] = ["/bin/cat", path.path]
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin"]
        let argv = argumentStrings.map { strdup($0) }
        let env = environmentStrings.map { strdup($0) }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        let args: [UnsafePointer<CChar>?] = argv.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        let environment: [UnsafePointer<CChar>?] = env.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        var output: Int32 = -1, gate: Int32 = -1
        let child = args.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { environment in
                keq_spawn_core("/bin/cat", args.baseAddress, environment.baseAddress, directory.path, childUID, childGID, &output, &gate)
            }
        }
        guard child > 0 else { throw ServiceFailure("test", "cannot spawn fixture reader") }
        defer { close(output); if gate >= 0 { close(gate) } }
        var token: UInt8 = 1
        guard Darwin.write(gate, &token, 1) == 1 else { throw ServiceFailure("test", "cannot release fixture reader") }
        close(gate); gate = -1
        var status: Int32 = 0, collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while true {
            CoreOutputReader.drain(output) { collected.append($0) }
            if waitpid(child, &status, WNOHANG) == child { break }
            if Date() >= deadline { kill(child, SIGKILL); _ = waitpid(child, &status, 0); throw ServiceFailure("test", "fixture reader timed out") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        CoreOutputReader.drain(output) { collected.append($0) }
        return (status, collected)
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o711])
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = umask(0o077)
        defer { umask(previous) }
        try inspect(directory, owner: 0, mode: 0o711)
        let fixtureGeo = Data("read-only fixture geodata\n".utf8)
        for mode in ["proxy", "tun"] {
            let home = directory.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in ["geoip.dat", "geosite.dat"] {
                let file = home.appendingPathComponent(name)
                try SecureFiles.write(fixtureGeo, to: file, mode: 0o644)
                try inspect(file, owner: 0, mode: 0o644)
            }
            let config = home.appendingPathComponent("config.json")
            let fixtureConfig = Data("{\"testCredential\":\"fixture-only\"}".utf8)
            try SecureFiles.write(fixtureConfig, to: config)
            try inspect(config, owner: 0, mode: 0o600)
            let legacyGeo = home.appendingPathComponent("legacy-geosite.dat")
            if mode == "proxy" {
                // Show that the former open(mode:0644)-only behavior really
                // denies this same UID, rather than testing stat bits alone.
                let legacyFD = open(legacyGeo.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                try require(legacyFD >= 0, "cannot create legacy umask fixture")
                close(legacyFD)
                try inspect(legacyGeo, owner: 0, mode: 0o600)
                try require(chown(config.path, uid, gid) == 0 && chown(home.path, uid, gid) == 0, "cannot prepare Proxy UID fixture")
            }
            try inspect(home, owner: mode == "proxy" ? uid : 0, mode: 0o700)
            let readerUID: uid_t = mode == "proxy" ? uid : 0
            let readerGID: gid_t = mode == "proxy" ? gid : 0
            for name in ["geoip.dat", "geosite.dat"] {
                let read = try readAs(home.appendingPathComponent(name), childUID: readerUID, childGID: readerGID)
                try require(read.status == 0 && read.output == fixtureGeo, "\(mode) actual child cannot read \(name)")
            }
            let readConfig = try readAs(config, childUID: readerUID, childGID: readerGID)
            try require(readConfig.status == 0 && readConfig.output == fixtureConfig, "\(mode) actual child cannot read its private config")
            if mode == "proxy" {
                let legacyRead = try readAs(legacyGeo, childUID: uid, childGID: gid)
                try require(legacyRead.status == 1 << 8, "legacy root0600 Geo fixture did not fail in cat after UID drop")
                try inspect(config, owner: uid, mode: 0o600)
            }
            let otherUID: uid_t = uid == 65534 ? 65533 : 65534
            let foreignGeo = try readAs(home.appendingPathComponent("geosite.dat"), childUID: otherUID, childGID: 65534)
            try require(foreignGeo.status == 1 << 8, "foreign UID was not denied private session geodata")
            let foreignConfig = try readAs(config, childUID: otherUID, childGID: 65534)
            try require(foreignConfig.status == 1 << 8, "foreign UID was not denied private config")
            if mode == "tun" {
                let callerRead = try readAs(config, childUID: uid, childGID: gid)
                try require(callerRead.status == 1 << 8, "Proxy UID was not denied root TUN config")
            }
        }
        return checks
    } catch { fputs("FAIL: privileged session file permissions: \(error.localizedDescription)\n", stderr); exit(1) }
}
