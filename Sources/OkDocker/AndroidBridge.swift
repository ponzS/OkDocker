import Foundation
import Network
import Darwin

// Token-authenticated transport: Apple uses a private Unix socket forwarded by
// the official runtime; legacy Docker uses Mac loopback. The raw ADB server
// remains at 127.0.0.1:5037; no USB ownership, credentials directory, or host shell
// is passed into the container. A separate process keeps running if the UI quits.
private final class BridgeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
enum AndroidBridge {
    static func launch(_ record: AppRecord, host: String = "127.0.0.1") throws -> [String: Any] {
        let root = Runtime.appDirectory(record)
        let receipt = root.appendingPathComponent("bridge-ready.json")
        if let data = try? Data(contentsOf: receipt), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = old["pid"] as? Int32, let token = old["token"] as? String, let port = old["port"] as? Int,
           processIsBridge(pid, marker: root.path), (old["listenHost"] as? String ?? "127.0.0.1") == host {
            return ["host": host == "127.0.0.1" ? "host.docker.internal" : host, "port": port, "token": token]
        }
        stop(record)
        _ = try Runtime.command(Runtime.find("adb"), ["start-server"], timeout: 15)
        try? FileManager.default.removeItem(at: receipt)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let config = root.appendingPathComponent("bridge-host.json")
        try Runtime.json(["token": token, "receipt": receipt.path, "listenHost": host], to: config)
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--adb-bridge", config.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: receipt), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let port = object["port"] as? Int {
                return ["host": host == "127.0.0.1" ? "host.docker.internal" : host, "port": port, "token": token]
            }
            if !process.isRunning { throw Problem("安卓接入助手启动失败") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        throw Problem("安卓接入助手未就绪")
    }
    static func unixSocket(_ record: AppRecord) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("okadb-" + String(AppleRuntime.scope.prefix(10))).appendingPathComponent(String(record.id.prefix(12)) + ".sock")
    }
    static func peerSocket(_ record: AppRecord) -> URL { unixSocket(record).deletingPathExtension().appendingPathExtension("peer.sock") }
    static func launchUnix(_ record: AppRecord) throws -> [String: Any] {
        let root = Runtime.appDirectory(record), path = unixSocket(record)
        guard path.path.utf8.count < 104, peerSocket(record).path.utf8.count < 104 else { throw Problem("系统临时目录的 Unix socket 路径过长") }
        let receipt = root.appendingPathComponent("bridge-ready.json")
        if let data = try? Data(contentsOf: receipt), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = old["pid"] as? Int32, let token = old["token"] as? String, old["socket"] as? String == path.path, processIsBridge(pid, marker: root.path) {
            return ["socket": "/run/host-adb.sock", "token": token]
        }
        stop(record)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.deletingLastPathComponent().path)
        _ = try Runtime.command(Runtime.find("adb"), ["start-server"], timeout: 15)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let config = root.appendingPathComponent("bridge-host.json")
        try Runtime.json(["token": token, "receipt": receipt.path, "listenSocket": path.path], to: config)
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--adb-bridge", config.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: receipt), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["socket"] as? String == path.path, object["token"] as? String == token { return ["socket": "/run/host-adb.sock", "token": token] }
            if !process.isRunning { throw Problem("安卓 Unix socket 助手启动失败") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        throw Problem("安卓 Unix socket 助手未就绪；不会改为开放网络监听")
    }
    static func processIsBridge(_ pid: Int32, marker: String) -> Bool {
        guard pid > 1, Darwin.kill(pid, 0) == 0,
              let result = try? Runtime.command("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3, allowFailure: true) else { return false }
        return result.output.contains("--adb-bridge") && result.output.contains(marker + "/bridge-host.json")
    }
    static func stop(_ record: AppRecord) {
        let root = Runtime.appDirectory(record), receipt = root.appendingPathComponent("bridge-ready.json")
        if let data = try? Data(contentsOf: receipt), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = object["pid"] as? Int32, processIsBridge(pid, marker: root.path) {
            Darwin.kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: unixSocket(record))
        try? FileManager.default.removeItem(at: peerSocket(record))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("android-config/bridge.json"))
        for name in ["bridge-ready.json", "bridge-host.json", "bridge-client.json"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    }
    static func run(config: URL) async throws {
        let data = try Data(contentsOf: config)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], let token = object["token"], let receipt = object["receipt"] else { throw Problem("Invalid bridge configuration") }
        let params = NWParameters.tcp
        let listenHost = object["listenHost"] ?? "127.0.0.1"
        let listenSocket = object["listenSocket"]
        if let listenSocket { params.requiredLocalEndpoint = .unix(path: listenSocket) }
        else { params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost), port: .any) }
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "dev.okdocker.adb", attributes: .concurrent)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                let handshakeTimeout = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { connection.cancel() } }
                defer { handshakeTimeout.cancel(); connection.cancel() }
                do {
                    let auth = try await receive(connection, exact: token.utf8.count + 1)
                    guard auth == Data((token + "\n").utf8) else { return }
                    let header = try await receive(connection, exact: 4)
                    guard let text = String(data: header, encoding: .ascii), let length = Int(text, radix: 16), length > 0, length <= 65535 else { return }
                    let request = try await receive(connection, exact: length)
                    handshakeTimeout.cancel()
                    let textRequest = String(data: request, encoding: .utf8) ?? ""
                    // Prevent an app/client-version mismatch from shutting down the
                    // shared Mac server. Android-side operations remain broad opt-in.
                    if textRequest == "host:kill" || textRequest.hasPrefix("host:kill:") {
                        let reason = "OkDocker forbids stopping the shared ADB server"
                        try await send(connection, Data(("FAIL" + String(format: "%04x", reason.utf8.count) + reason).utf8))
                        return
                    }
                    let upstream = NWConnection(host: "127.0.0.1", port: 5037, using: .tcp)
                    defer { upstream.cancel() }
                    try await connect(upstream, queue: queue)
                    try await send(upstream, header + request)
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await pump(connection, upstream) }
                        group.addTask { await pump(upstream, connection) }
                        _ = await group.next()
                        connection.cancel(); upstream.cancel(); group.cancelAll()
                    }
                } catch { /* Closed/unauthorized transports are not logged with tokens. */ }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let announced = BridgeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard announced.claim() else { return }
                    do {
                        var ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "token": token]
                        if let listenSocket {
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listenSocket)
                            ready["socket"] = listenSocket
                        } else if let port = listener.port { ready["port"] = Int(port.rawValue); ready["listenHost"] = listenHost }
                        else { throw Problem("ADB listener has no endpoint") }
                        try Runtime.json(ready, to: URL(fileURLWithPath: receipt))
                    } catch { continuation.resume(throwing: error); listener.cancel() }
                case .failed(let error): if announced.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
            // This process lives until the app's containers are force-closed.
            // The pending continuation deliberately retains the listener.
        }
    }
    private static func connect(_ c: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = BridgeOnce()
            c.stateUpdateHandler = { state in
                switch state { case .ready: if done.claim() { continuation.resume() }; case .failed(let error): if done.claim() { continuation.resume(throwing: error) }; default: break }
            }
            c.start(queue: queue)
        }
    }
    private static func receive(_ c: NWConnection, exact count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            c.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Problem(complete ? "Connection closed" : "Short bridge frame")) }
            }
        }
    }
    private static func send(_ c: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } })
        }
    }
    private static func pump(_ from: NWConnection, _ to: NWConnection) async {
        do {
            while !Task.isCancelled {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                if data.isEmpty { break }
                try await send(to, data)
            }
        } catch { }
    }
}
