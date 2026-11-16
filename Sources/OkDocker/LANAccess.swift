import Foundation
import Darwin

// Optional host-side TCP publication. Container ports remain audited loopback-only:
// changing a running VM's publication would require replacing its writable layer.
// This separate, scoped helper keeps LAN policy outside the deployment and UI lifetime.
struct LANStatus: Codable {
    var enabled: Bool
    var addresses: [String] = []
    var error: String = ""
}
struct LANLease: Codable, Sendable {
    var port: Int
    var pid: Int32
    var identity: String
}
private struct LANConfiguration: Codable, Sendable {
    var appID: String
    var manifestHash: String
    var nonce: String
    var leases: [LANLease]
}
private struct LANReceipt: Codable {
    var pid: Int32
    var nonce: String
    var addresses: [String]
    var error: String
}
enum LANAccess {
    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ guard let byte = UInt8($0) else { return false }; return String(byte) == $0 }) else { return false }
        let a = parts.map { Int($0)! }
        return a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168)
    }
    static func interfaceAllowed(_ name: String) -> Bool { name.range(of: "^en[0-9]+$", options: .regularExpression) != nil }
    static func addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var result: Set<String> = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let value = item.pointee
            guard let addr = value.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  interfaceAllowed(String(cString: value.ifa_name)),
                  value.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            if isPrivateIPv4(host) { result.insert(host) }
        }
        return result.sorted()
    }
    static func url(_ endpoint: Endpoint, host: String) -> URL? {
        guard isPrivateIPv4(host) else { return nil }
        return URL(string: "http://\(host):\(endpoint.hostPort)\(endpoint.path)")
    }
    private static func configURL(_ record: AppRecord) -> URL { Runtime.appDirectory(record).appendingPathComponent("lan-host.json") }
    private static func receiptURL(_ record: AppRecord) -> URL { Runtime.appDirectory(record).appendingPathComponent("lan-ready.json") }
    private static func withLock<T>(_ record: AppRecord, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: Runtime.appDirectory(record), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(Runtime.appDirectory(record).appendingPathComponent("lan.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(tr("无法锁定局域网入口")) }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Problem(tr("无法锁定局域网入口")) }
        return try body()
    }
    private static func helper(_ pid: Int32, _ record: AppRecord) -> Bool {
        guard pid > 1, kill(pid, 0) == 0,
              let result = try? Runtime.command("/bin/ps", ["-p", String(pid), "-o", "uid=,command="], timeout: 3, allowFailure: true) else { return false }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(String(getuid()) + " ") && text.contains("/OkDocker --lan-gateway ") && text.hasSuffix(configURL(record).path)
    }
    private static func receipt(_ record: AppRecord) -> LANReceipt? {
        guard let data = try? Data(contentsOf: receiptURL(record)), let value = try? JSONDecoder().decode(LANReceipt.self, from: data), helper(value.pid, record) else { return nil }
        return value
    }
    static func status(_ record: AppRecord) -> LANStatus {
        guard record.lanAccess == true else { return LANStatus(enabled: false) }
        guard let value = receipt(record) else { return LANStatus(enabled: true, error: tr("入口未运行；应用启动时开启，或重新打开此开关")) }
        return LANStatus(enabled: true, addresses: value.addresses, error: value.error)
    }
    private static func identity(_ pid: Int32) throws -> String {
        try Runtime.command("/bin/ps", ["-p", String(pid), "-o", "lstart=,command="], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Capture the actual loopback publisher, not any arbitrary local service at
    // the same port. Recheck for every new connection to prevent port reuse from
    // exposing an unrelated service after the managed application exits.
    private static func leases(_ record: AppRecord, _ v: Validated) throws -> [LANLease] {
        guard record.context == AppleRuntime.context else { throw Problem(tr("请先迁移到 Apple container 再开启局域网入口")) }
        let endpoints = [v.manifest.frontend, v.manifest.backend]
        return try Set(endpoints.map(\.hostPort)).sorted().map { port in
            let output = try Runtime.command("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"], timeout: 5).output
            let lines = output.split(separator: "\n").map(String.init)
            let pids = Set(lines.filter { $0.hasPrefix("p") }.compactMap { Int32($0.dropFirst()) })
            guard pids.count == 1, let pid = pids.first,
                  lines.filter({ $0.hasPrefix("n") }) == ["n127.0.0.1:\(port)"] else { throw Problem(L("Port \(port) is not the only local listener, so LAN forwarding was not enabled", "端口 \(port) 不是唯一的本机入口，不能开启局域网转发")) }
            let signature = try identity(pid)
            let service = endpoints.first { $0.hostPort == port }!.service
            let container = NSRegularExpression.escapedPattern(for: AppleRuntime.name(record, service))
            guard signature.contains("/container-runtime-linux "), signature.range(of: "(?<![a-zA-Z0-9-])" + container + "(?![a-zA-Z0-9-])", options: .regularExpression) != nil else { throw Problem(L("Port \(port) does not belong to this app's Apple container", "端口 \(port) 不属于这个应用的 Apple 容器")) }
            return LANLease(port: port, pid: pid, identity: signature)
        }
    }
    static func valid(_ lease: LANLease) -> Bool {
        guard (try? identity(lease.pid)) == lease.identity,
              let output = try? Runtime.command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(lease.pid), "-iTCP:\(lease.port)", "-sTCP:LISTEN", "-Fn"], timeout: 3).output else { return false }
        return output.split(separator: "\n").contains(Substring("n127.0.0.1:\(lease.port)"))
    }
    private static func stopUnlocked(_ record: AppRecord) throws {
        var pids: Set<Int32> = []
        if let old = receipt(record) { pids.insert(old.pid) }
        // Also revoke a helper whose launcher died before it wrote a receipt.
        let pattern = "--lan-gateway " + NSRegularExpression.escapedPattern(for: configURL(record).path) + "$"
        let found = try Runtime.command("/usr/bin/pgrep", ["-u", String(getuid()), "-f", "--", pattern], timeout: 3, allowFailure: true)
        for line in found.output.split(whereSeparator: \.isWhitespace) { if let pid = Int32(line), helper(pid, record) { pids.insert(pid) } }
        for pid in pids {
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw Problem(tr("无法关闭局域网助手")) }
            for _ in 0..<50 {
                if kill(pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !helper(pid, record) else { throw Problem(tr("局域网助手尚未退出，未确认入口关闭")) }
        }
        for file in [receiptURL(record), configURL(record)] { try? FileManager.default.removeItem(at: file) }
    }
    static func stop(_ record: AppRecord) throws { try withLock(record) { try stopUnlocked(record) } }
    static func ensure(_ record: AppRecord) throws {
        try withLock(record) {
            let latest = try Runtime.record(record.id)
            guard latest.lanAccess == true else { try stopUnlocked(record); return }
            guard !FileManager.default.fileExists(atPath: Runtime.appDirectory(latest).appendingPathComponent("stop.request").path) else { throw Problem(tr("应用正在关闭；下次启动时恢复局域网入口")) }
            if receipt(latest) != nil { return }
            guard !addresses().isEmpty else { throw Problem(tr("没有可用的 Wi-Fi/以太网私有 IPv4 地址；未开放公网或 VPN 接口")) }
            let v = try Runtime.approved(latest)
            let config = LANConfiguration(appID: latest.id, manifestHash: latest.manifestHash, nonce: UUID().uuidString, leases: try leases(latest, v))
            try stopUnlocked(latest)
            try Runtime.write(JSONEncoder().encode(config), to: configURL(latest))
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--lan-gateway", configURL(latest).path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            for _ in 0..<120 {
                if let ready = receipt(latest), ready.nonce == config.nonce {
                    if !ready.error.isEmpty { try stopUnlocked(latest); throw Problem(ready.error) }
                    if !ready.addresses.isEmpty { return }
                }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw Problem(tr("局域网助手未就绪；请检查系统本地网络与防火墙提示，不会自动放宽系统权限"))
        }
    }
    static func set(_ record: AppRecord, enabled: Bool) throws -> String {
        try FileManager.default.createDirectory(at: Runtime.appDirectory(record), withIntermediateDirectories: true)
        let gate = Darwin.open(Runtime.appDirectory(record).appendingPathComponent("stop.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard gate >= 0 else { throw Problem(tr("无法锁定局域网授权")) }
        defer { flock(gate, LOCK_UN); Darwin.close(gate) }
        if enabled {
            guard flock(gate, LOCK_SH | LOCK_NB) == 0 else { throw Problem(tr("应用正在关闭，请稍后再设置")) }
            _ = try Runtime.approved(record)
            guard record.context == AppleRuntime.context else { throw Problem(tr("请先迁移到 Apple container")) }
        }
        try Runtime.transaction { registry in
            guard let i = registry.apps.firstIndex(where: { $0.id == record.id }) else { throw Problem(tr("应用已移除")) }
            registry.apps[i].lanAccess = enabled
        }
        if !enabled { try stop(record); return tr("已关闭局域网访问，本机入口与容器保持不变") }
        if try Runtime.observe(record).running == 0 { return tr("已允许局域网访问，下次启动应用时生效") }
        do { try ensure(record) }
        catch {
            try Runtime.transaction { registry in if let i = registry.apps.firstIndex(where: { $0.id == record.id }) { registry.apps[i].lanAccess = false } }
            try? stop(record); throw error
        }
        return tr("已开启局域网访问，容器和数据未重建")
    }
    private static func canListen(_ lease: LANLease) -> Bool {
        guard let result = try? Runtime.command("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(lease.port)", "-sTCP:LISTEN", "-Fpn"], timeout: 3) else { return false }
        var pid: Int32 = 0
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n"), pid != getpid(), !(pid == lease.pid && line == "n127.0.0.1:\(lease.port)") { return false }
        }
        return true
    }
    static func run(config url: URL) async throws {
        let config = try JSONDecoder().decode(LANConfiguration.self, from: Data(contentsOf: url))
        let record = try Runtime.record(config.appID)
        guard url.standardizedFileURL == configURL(record).standardizedFileURL, record.lanAccess == true, record.manifestHash == config.manifestHash,
              !config.leases.isEmpty, config.leases.allSatisfy({ (1024...65535).contains($0.port) && valid($0) }) else { throw Problem(tr("局域网授权或服务入口已改变")) }
        await LANServer(record: record, config: config).run()
    }
    // POSIX is deliberate: NWListener reserves a port more broadly and returned
    // EADDRINUSE beside the official loopback publisher, although specific-address
    // bind/listen works. Never work around this by binding a wildcard or replacing VM data.
    private final class TCPListener {
        let source: DispatchSourceRead
        init(host: String, port: Int, accept: @escaping @Sendable (Int32) -> Void) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Problem(tr("无法创建局域网 socket")) }
            var success = false; defer { if !success { Darwin.close(fd) } }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr(host)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, Darwin.listen(fd, 64) == 0 else { throw Problem(L("Listen failed: \(String(cString: strerror(errno)))", "监听失败：\(String(cString: strerror(errno)))")) }
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.okdocker.lan.accept"))
            source.setEventHandler {
                while true {
                    var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &size) } }
                    if client < 0 { break }
                    var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    _ = inet_ntop(AF_INET, &peer.sin_addr, &chars, socklen_t(chars.count))
                    guard LANAccess.isPrivateIPv4(String(cString: chars)) else { Darwin.close(client); continue }
                    _ = fcntl(client, F_SETFD, FD_CLOEXEC); _ = fcntl(client, F_SETFL, O_NONBLOCK)
                    accept(client)
                }
            }
            source.setCancelHandler { Darwin.close(fd) }; success = true; source.resume()
        }
        func cancel() { source.cancel() }
    }
    private final class TCPPair: @unchecked Sendable {
        private let lock = NSLock()
        private var client: Int32
        private var upstream: Int32 = -1
        private var cancelled = false
        init(_ client: Int32) { self.client = client }
        func stop() { lock.lock(); defer { lock.unlock() }; cancelled = true; if client >= 0 { shutdown(client, SHUT_RDWR) }; if upstream >= 0 { shutdown(upstream, SHUT_RDWR) } }
        func finish() { lock.lock(); let c = client, u = upstream; client = -1; upstream = -1; lock.unlock(); if c >= 0 { Darwin.close(c) }; if u >= 0 { Darwin.close(u) } }
        private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func forward(port: Int) {
            defer { finish() }
            guard !stopped else { return }
            let u = socket(AF_INET, SOCK_STREAM, 0); guard u >= 0 else { return }
            lock.lock(); if cancelled { lock.unlock(); Darwin.close(u); return }; upstream = u; let c = client; lock.unlock()
            _ = fcntl(u, F_SETFD, FD_CLOEXEC); _ = fcntl(u, F_SETFL, O_NONBLOCK)
            var one: Int32 = 1
            for fd in [c, u] { _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(u, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { return }
                var item = pollfd(fd: u, events: Int16(POLLOUT), revents: 0)
                guard poll(&item, 1, 5000) > 0, !stopped else { return }
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(u, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return }
            }
            var toClient = Data(), toUpstream = Data(), clientEOF = false, upstreamEOF = false, clientFIN = false, upstreamFIN = false
            func read(_ fd: Int32, into data: inout Data, eof: inout Bool) -> Bool {
                var bytes = [UInt8](repeating: 0, count: min(32768, 65536 - data.count))
                let count = recv(fd, &bytes, bytes.count, 0)
                if count > 0 { data.append(contentsOf: bytes.prefix(count)); return true }
                if count == 0 { eof = true; return true }
                return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
            }
            func write(_ fd: Int32, _ data: inout Data) -> Bool {
                let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                if count > 0 { data.removeFirst(count); return true }
                return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            }
            // One bounded worker per connection, <=64 connections; each direction
            // buffers at most 64 KiB and poll supplies backpressure/half-close.
            while !stopped {
                if clientEOF && toUpstream.isEmpty && !upstreamFIN { shutdown(u, SHUT_WR); upstreamFIN = true }
                if upstreamEOF && toClient.isEmpty && !clientFIN { shutdown(c, SHUT_WR); clientFIN = true }
                if clientEOF && upstreamEOF && toUpstream.isEmpty && toClient.isEmpty { break }
                let ce = (!clientEOF && toUpstream.count < 65536 ? Int16(POLLIN) : 0) | (!toClient.isEmpty ? Int16(POLLOUT) : 0)
                let ue = (!upstreamEOF && toClient.count < 65536 ? Int16(POLLIN) : 0) | (!toUpstream.isEmpty ? Int16(POLLOUT) : 0)
                var items = [pollfd(fd: ce == 0 ? -1 : c, events: ce, revents: 0), pollfd(fd: ue == 0 ? -1 : u, events: ue, revents: 0)]
                let count = poll(&items, 2, 1000)
                if count < 0 { if errno == EINTR { continue }; break }
                if items.contains(where: { $0.revents & Int16(POLLNVAL | POLLERR) != 0 }) { break }
                if !clientEOF && toUpstream.count < 65536 && items[0].revents & Int16(POLLIN | POLLHUP) != 0 { if !read(c, into: &toUpstream, eof: &clientEOF) { break } }
                if !upstreamEOF && toClient.count < 65536 && items[1].revents & Int16(POLLIN | POLLHUP) != 0 { if !read(u, into: &toClient, eof: &upstreamEOF) { break } }
                if !toClient.isEmpty && items[0].revents & Int16(POLLOUT) != 0 { if !write(c, &toClient) { break } }
                if !toUpstream.isEmpty && items[1].revents & Int16(POLLOUT) != 0 { if !write(u, &toUpstream) { break } }
            }
        }
    }
    @MainActor private final class LANServer {
        let record: AppRecord
        let config: LANConfiguration
        var listeners: [String: TCPListener] = [:]
        var errors: [String: String] = [:]
        var connections: [UUID: TCPPair] = [:]
        init(record: AppRecord, config: LANConfiguration) { self.record = record; self.config = config }
        func publish() {
            let hosts = LANAccess.addresses().filter { host in config.leases.allSatisfy { listeners["\(host):\($0.port)"] != nil } }
            let value = LANReceipt(pid: getpid(), nonce: config.nonce, addresses: hosts, error: errors.values.sorted().joined(separator: "; "))
            if let data = try? JSONEncoder().encode(value) { try? Runtime.write(data, to: receiptURL(record)) }
        }
        func run() async {
            defer { for l in listeners.values { l.cancel() }; for pair in connections.values { pair.stop() }; try? FileManager.default.removeItem(at: receiptURL(record)) }
            while !Task.isCancelled {
                guard let current = try? Runtime.record(record.id), current.lanAccess == true, current.manifestHash == config.manifestHash,
                      !FileManager.default.fileExists(atPath: Runtime.appDirectory(record).appendingPathComponent("stop.request").path) else { break }
                guard await Task.detached(operation: { self.config.leases.allSatisfy { LANAccess.valid($0) } }).value else { break }
                let hosts = LANAccess.addresses(), oldHosts = Set(listeners.keys.compactMap { $0.split(separator: ":").first.map(String.init) })
                if oldHosts != Set(hosts) { for pair in connections.values { pair.stop() } }
                let desired = Set(hosts.flatMap { host in config.leases.map { "\(host):\($0.port)" } })
                for key in Array(listeners.keys) where !desired.contains(key) { listeners.removeValue(forKey: key)?.cancel(); errors.removeValue(forKey: key) }
                for host in hosts { for lease in config.leases {
                    let key = "\(host):\(lease.port)"; guard listeners[key] == nil else { continue }
                    guard await Task.detached(operation: { LANAccess.canListen(lease) }).value else { errors[key] = L("\(key) conflicts with another listener; its port was not taken over", "\(key) 与其他监听冲突，未覆盖其端口"); continue }
                    do {
                        listeners[key] = try TCPListener(host: host, port: lease.port) { fd in Task { @MainActor in self.accept(fd, lease: lease, key: key) } }
                        errors.removeValue(forKey: key)
                    } catch { errors[key] = "\(key) \(error.localizedDescription)" }
                } }
                publish(); try? await Task.sleep(for: .seconds(2))
            }
        }
        func accept(_ fd: Int32, lease: LANLease, key: String) {
            guard connections.count < 64, listeners[key] != nil else { Darwin.close(fd); return }
            let id = UUID(), pair = TCPPair(fd); connections[id] = pair
            DispatchQueue.global(qos: .utility).async {
                if LANAccess.valid(lease) { pair.forward(port: lease.port) } else { pair.finish() }
                Task { @MainActor in self.connections.removeValue(forKey: id) }
            }
        }
    }
}
