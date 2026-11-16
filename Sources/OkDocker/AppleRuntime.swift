import Foundation
import Darwin

// Official CLI adapter only. Runtime owns approvals, operation locks and cancellation.
// No Docker daemon/context, shell expansion, imported Compose, or VM reimplementation.
enum AppleRuntime {
    static let context = "apple-container"
    static let testedVersion = "1.7.1"
    static var scope: String { digest(Data(Runtime.support.standardizedFileURL.path.utf8)) }
    static func checkPlatform() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { throw Problem("Apple container 需要 macOS 26 或更新版本") }
        #if !arch(arm64)
        throw Problem("Apple container 后端仅支持 Apple Silicon；不使用隐式 x86 模拟")
        #endif
    }
    static func cli(_ args: [String], timeout: TimeInterval = 30, allowFailure: Bool = false, cwd: URL? = nil) throws -> CommandResult {
        try checkPlatform()
        return try Runtime.command(Runtime.find("container"), args, timeout: timeout, cwd: cwd, allowFailure: allowFailure)
    }
    static func array(_ output: String) throws -> [[String: Any]] {
        guard let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { throw Problem("Apple container 返回了无法识别的数据；未确认实际状态") }
        return value
    }
    static func engine() throws -> String {
        let output = try cli(["system", "status", "--format", "json"], timeout: 10).output
        guard let status = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], status["status"] as? String == "running" else { throw Problem("Apple container 尚未启动，请点击“启动运行时”") }
        let version = (status["server"] as? [String: Any])?["version"] as? String ?? "unknown"
        guard version == testedVersion else { throw Problem("当前 Apple container \(version)，本版仅适配并验收 \(testedVersion)。请安装对应官方签名版本。") }
        return version
    }
    static func startEngine() throws -> String {
        _ = try cli(["system", "start", "--enable-kernel-install", "--timeout", "180"], timeout: 240)
        return "Apple container \(try engine()) 服务已启动；应用启动后还会检查实际文件与 HTTP I/O"
    }
    static func labels(_ record: AppRecord) -> [String: String] { ["dev.okdocker.app": record.id, "dev.okdocker.scope": scope] }
    static func owns(_ object: [String: Any], record: AppRecord) -> Bool {
        guard let config = object["configuration"] as? [String: Any], let actual = config["labels"] as? [String: String] else { return false }
        return labels(record).allSatisfy { actual[$0.key] == $0.value }
    }
    static func containers(_ record: AppRecord) throws -> [[String: Any]] {
        try array(cli(["list", "--all", "--format", "json"]).output).filter { owns($0, record: record) }
    }
    static func id(_ object: [String: Any]) throws -> String {
        guard let value = (object["configuration"] as? [String: Any])?["id"] as? String, !value.isEmpty else { throw Problem("Apple container 缺少容器 ID") }; return value
    }
    static func active(_ object: [String: Any]) -> Bool {
        // Unknown/transitioning states must not be reported as safely stopped.
        !["stopped", "created"].contains((object["status"] as? [String: Any])?["state"] as? String ?? "unknown")
    }
    static func observe(_ record: AppRecord) throws -> Observation {
        let all = try containers(record)
        let running = all.filter(active).count
        let started = all.filter { ($0["status"] as? [String: Any])?["state"] as? String == "running" }.count
        let saved = Runtime.appDirectory(record).appendingPathComponent("apple-plan.json")
        let expected = ((try? Data(contentsOf: saved)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["count"] as? Int
        if running == 0 { return Observation(state: "stopped", detail: "Apple 容器已停止，挂载数据和现有容器可写层保留", containers: all.count, running: 0, healthy: nil) }
        if let expected, all.count != expected { return Observation(state: "partial", detail: "Apple 容器缺失：\(all.count)/\(expected)", containers: all.count, running: running, healthy: false) }
        return Observation(state: started == all.count ? "running" : "partial", detail: "Apple 轻量 VM：\(started)/\(all.count) 个容器运行", containers: all.count, running: running, healthy: nil)
    }
    static func name(_ record: AppRecord, _ service: String) -> String { record.project + "-" + service }
    static func mountArgument(source: String, target: String, readOnly: Bool) throws -> String {
        guard ![source, target].contains(where: { $0.contains(",") || $0.contains("\0") || $0.contains("\n") }) else { throw Problem("Apple mount 参数不能无歧义表示含逗号、换行或 NUL 的路径，请先重命名") }
        return "type=bind,source=\(source),target=\(target)" + (readOnly ? ",readonly" : "")
    }
    static func createArguments(_ record: AppRecord, service: String, spec: ServiceSpec, validated v: Validated, image: String, extraEnvironment: [String: String] = [:]) throws -> [String] {
        var args = ["create", "--name", name(record, service), "--platform", "linux/arm64", "--network", record.project, "--init", "--cap-drop", "NET_RAW"]
        for (key, value) in labels(record).merging(["dev.okdocker.manifest": v.hash, "dev.okdocker.service": service], uniquingKeysWith: { _, b in b }).sorted(by: { $0.key < $1.key }) { args += ["--label", "\(key)=\(value)"] }
        for mount in spec.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] {
            args += ["--mount", try mountArgument(source: contained(mount.source, root: v.root, directory: true).path, target: mount.target, readOnly: mount.readOnly ?? false)]
        }
        if let wd = spec.workingDirectory { args += ["--workdir", wd] }
        for (key, value) in (spec.environment ?? [:]).merging(extraEnvironment, uniquingKeysWith: { _, b in b }).sorted(by: { $0.key < $1.key }) {
            guard !value.contains("\0") else { throw Problem("环境变量不能包含 NUL") }
            args += ["--env", "\(key)=\(value)"]
        }
        for port in Set([v.manifest.frontend, v.manifest.backend].filter { $0.service == service }.map { "127.0.0.1:\($0.hostPort):\($0.containerPort)/tcp" }).sorted() { args += ["--publish", port] }
        if v.manifest.hostAndroidDevices == true && service == v.manifest.backend.service {
            args += ["--volume", AndroidBridge.peerSocket(record).path + ":/run/okdocker-adb.sock"]
        }
        return args + ["--", image] + (spec.command ?? [])
    }
    static func network(_ record: AppRecord, create: Bool) throws -> [String: Any]? {
        let networks = try array(cli(["network", "list", "--format", "json"]).output)
        if let found = networks.first(where: { ($0["configuration"] as? [String: Any])?["name"] as? String == record.project }) {
            guard owns(found, record: record) else { throw Problem("同名网络不属于该应用，拒绝接管") }
            return found
        }
        if !create { return nil }
        var args = ["network", "create"]
        for (key, value) in labels(record).sorted(by: { $0.key < $1.key }) { args += ["--label", "\(key)=\(value)"] }
        _ = try cli(args + [record.project])
        return try network(record, create: false)
    }
    static func image(_ record: AppRecord, service: String, spec: ServiceSpec, root: URL) throws -> String {
        if let build = spec.build {
            let image = "okdocker.local/\(record.project)/\(service):\(scope.prefix(12))"
            let directory = try contained(build.context, root: root, directory: true)
            let dockerfile = try contained(build.dockerfile, root: directory, directory: false)
            let result = try cli(["build", "--platform", "linux/arm64", "--progress", "plain", "--tag", image, "--label", "dev.okdocker.app=\(record.id)", "--label", "dev.okdocker.scope=\(scope)", "--file", dockerfile.path, directory.path], timeout: 1800, cwd: directory)
            try Runtime.write(Data(result.output.utf8), to: Runtime.appDirectory(record).appendingPathComponent("last-build.log"))
            return image
        }
        guard let image = spec.image else { throw Problem("服务缺少镜像") }
        if try cli(["image", "inspect", image], allowFailure: true).code != 0 { _ = try cli(["image", "pull", "--platform", "linux/arm64", "--", image], timeout: 1800) }
        return image
    }
    // Audit the actual, stopped container BEFORE starting it. Fail closed when the
    // upstream JSON format changes; never trust a successful create alone.
    static func audit(_ object: [String: Any], record: AppRecord, v: Validated, service: String, spec: ServiceSpec, privateMount: String? = nil) throws {
        guard owns(object, record: record), let c = object["configuration"] as? [String: Any],
              (c["labels"] as? [String: String])?["dev.okdocker.manifest"] == v.hash,
              c["ssh"] as? Bool != true, c["rosetta"] as? Bool != true, c["virtualization"] as? Bool != true,
              (c["capAdd"] as? [String] ?? []).isEmpty,
              (c["platform"] as? [String: Any])?["architecture"] as? String == "arm64",
              (c["platform"] as? [String: Any])?["os"] as? String == "linux",
              c["runtimeHandler"] as? String == "container-runtime-linux", c["useInit"] as? Bool == true,
              !(Set(c["capDrop"] as? [String] ?? []).intersection(["CAP_NET_RAW", "ALL"]).isEmpty) else { throw Problem("Apple 容器实际权限或配置摘要不符合本次授权") }
        let mounts = c["mounts"] as? [[String: Any]] ?? []
        var expected: Set<String> = []
        if let privateMount {
            expected.insert(privateMount + "|/run/okdocker|true")
            expected.insert(AndroidBridge.unixSocket(record).path + "|/run/host-adb.sock|false")
        }
        else {
            for m in spec.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] { expected.insert(try contained(m.source, root: v.root).path + "|" + m.target + "|\(m.readOnly ?? false)") }
        }
        if privateMount == nil && v.manifest.hostAndroidDevices == true && service == v.manifest.backend.service { expected.insert(AndroidBridge.peerSocket(record).path + "|/run/okdocker-adb.sock|false") }
        let sockets = c["publishedSockets"] as? [[String: Any]] ?? []
        if privateMount != nil {
            guard sockets.count == 1, sockets[0]["hostPath"] as? String == AndroidBridge.peerSocket(record).path, sockets[0]["containerPath"] as? String == "/run/adb-client.sock" else { throw Problem("ADB sidecar socket 转发不符合授权") }
        } else { guard sockets.isEmpty else { throw Problem("应用包含未授权 socket 发布") } }
        guard mounts.allSatisfy({ ($0["type"] as? [String: Any])?["virtiofs"] != nil }) else { throw Problem("Apple 容器包含未授权类型的挂载") }
        let actual = Set(mounts.map { m in "\(m["source"] as? String ?? "?")|\(m["destination"] as? String ?? "?")|\((m["options"] as? [String] ?? []).contains("ro"))" })
        guard actual == expected, mounts.count == expected.count else { throw Problem("Apple 容器实际挂载与授权不一致") }
        let networks = c["networks"] as? [[String: Any]] ?? []
        guard networks.count == 1, networks[0]["network"] as? String == record.project else { throw Problem("Apple 容器接入了未授权网络") }
        let allowed = Set([v.manifest.frontend, v.manifest.backend].filter { $0.service == service }.map { "\($0.hostPort)|\($0.containerPort)" })
        let ports = c["publishedPorts"] as? [[String: Any]] ?? []
        guard ports.allSatisfy({ p in p["hostAddress"] as? String == "127.0.0.1" && (p["count"] as? Int ?? 1) == 1 && (p["proto"] as? String == "tcp") && allowed.contains("\(p["hostPort"] as? Int ?? -1)|\(p["containerPort"] as? Int ?? -1)") }), ports.count == allowed.count else { throw Problem("Apple 容器端口不符合 loopback 授权") }
    }
    static func inspect(_ name: String) throws -> [String: Any] {
        guard let c = try array(cli(["inspect", name]).output).first else { throw Problem("创建后未观察到 Apple 容器") }; return c
    }
    static func start(_ record: AppRecord) throws -> String {
        let v = try Runtime.approved(record); _ = try engine()
        for (service, spec) in v.manifest.services {
            _ = try createArguments(record, service: service, spec: spec, validated: v, image: spec.image ?? "okdocker-preflight")
        }
        var existing = try containers(record)
        let expected = Set(v.manifest.services.keys).union(v.manifest.hostAndroidDevices == true ? ["okdocker-adb"] : [])
        let current = try observe(record)
        if current.running > 0 {
            guard current.state == "running", current.containers == expected.count else { throw Problem("应用部分运行，请先强制关闭后重试") }
            return "\(record.name) 已在运行"
        }
        try LANAccess.stop(record)
        for port in Set([v.manifest.frontend.hostPort, v.manifest.backend.hostPort]) { try Runtime.requireFreePort(port) }
        if !existing.isEmpty {
            guard existing.allSatisfy({ (($0["configuration"] as? [String: Any])?["labels"] as? [String: String])?["dev.okdocker.manifest"] == v.hash }) else { throw Problem("现有容器使用旧配置。为保护容器可写层，未自动删除。请先备份容器内数据，移除旧登记后重新导入；宿主应用目录保留。") }
        }
        _ = try network(record, create: true)
        var images: [String: String] = [:]
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) where !existing.contains(where: { (($0["configuration"] as? [String: Any])?["labels"] as? [String: String])?["dev.okdocker.service"] == service }) {
            images[service] = try image(record, service: service, spec: spec, root: v.root)
        }
        _ = try Runtime.approved(record) // Approval may have changed during a long build.
        var adbAddress: String?
        if v.manifest.hostAndroidDevices == true { adbAddress = try startAndroid(record, v: v, existing: existing) }
        for port in Set([v.manifest.frontend.hostPort, v.manifest.backend.hostPort]) { try Runtime.requireFreePort(port) }
        _ = try Runtime.approved(record)
        try Runtime.json(["count": expected.count, "manifestHash": v.hash], to: Runtime.appDirectory(record).appendingPathComponent("apple-plan.json"))
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) {
            let containerName = name(record, service)
            let old = existing.first { (($0["configuration"] as? [String: Any])?["labels"] as? [String: String])?["dev.okdocker.service"] == service }
            if old == nil {
                let env = service == v.manifest.backend.service ? adbAddress.map { ["ADB_SERVER_SOCKET": $0] } ?? [:] : [:]
                _ = try cli(createArguments(record, service: service, spec: spec, validated: v, image: images[service]!, extraEnvironment: env), timeout: 120)
            } else if adbAddress != nil && service == v.manifest.backend.service {
                // Verify the existing backend still uses our fixed, explicitly
                // approved Unix transport; VM IP changes are irrelevant.
                let env = (((old?["configuration"] as? [String: Any])?["initProcess"] as? [String: Any])?["environment"] as? [String]) ?? []
                guard env.contains("ADB_SERVER_SOCKET=\(adbAddress!)") else { throw Problem("ADB 通道配置与现有容器不符；未删除旧容器。请备份容器内数据后移除登记并重新导入。") }
            }
            try audit(inspect(containerName), record: record, v: v, service: service, spec: spec)
            _ = try cli(["start", containerName], timeout: 120)
        }
        existing = try containers(record)
        guard existing.count == expected.count, existing.allSatisfy({ ($0["status"] as? [String: Any])?["state"] as? String == "running" }) else { throw Problem("未观察到全部 Apple 容器运行；请查看实际状态或强制关闭") }
        return "已启动 \(record.name) · Apple container"
    }
    static func startAndroid(_ record: AppRecord, v: Validated, existing: [[String: Any]]) throws -> String {
        let bridge = try AndroidBridge.launchUnix(record)
        let configDirectory = Runtime.appDirectory(record).appendingPathComponent("android-config")
        let config = configDirectory.appendingPathComponent("bridge.json")
        var clientConfig = bridge; clientConfig["listenSocket"] = "/run/adb-client.sock"
        try Runtime.json(clientConfig, to: config)
        // Guest sidecar has no capabilities. This directory alone is exported
        // read-only; its Mac ancestors remain 0700, preventing other users' access.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        let dir = Runtime.appDirectory(record).appendingPathComponent("android-client")
        for filename in ["Dockerfile", "client.py"] { try Runtime.write(Data(contentsOf: Runtime.resources.appendingPathComponent("Android/" + filename)), to: dir.appendingPathComponent(filename)) }
        let spec = ServiceSpec(build: BuildSpec(context: ".", dockerfile: "Dockerfile"), mounts: [])
        let containerName = name(record, "okdocker-adb")
        if !existing.contains(where: { (try? id($0)) == containerName }) {
            let ref = try image(record, service: "okdocker-adb", spec: spec, root: dir)
            var args = try createArguments(record, service: "okdocker-adb", spec: spec, validated: v, image: ref)
            args.insert(contentsOf: ["--cap-drop", "ALL", "--publish-socket", AndroidBridge.peerSocket(record).path + ":/run/adb-client.sock", "--mount", try mountArgument(source: configDirectory.path, target: "/run/okdocker", readOnly: true), "--env", "OKDOCKER_BRIDGE_CONFIG=/run/okdocker/bridge.json", "--volume", AndroidBridge.unixSocket(record).path + ":/run/host-adb.sock"], at: 1)
            _ = try cli(args, timeout: 120)
        }
        try audit(inspect(containerName), record: record, v: v, service: "okdocker-adb", spec: spec, privateMount: configDirectory.path)
        _ = try cli(["start", containerName], timeout: 120)
        return "localfilesystem:/run/okdocker-adb.sock"
    }
    static func cancelLaunchers(_ record: AppRecord) throws {
        let ownedNames = Set(try containers(record).map(id))
        let found = try Runtime.command("/usr/bin/pgrep", ["-u", String(getuid()), "-f", "(^|/)(container (create|start|build|image pull|network create)|build) "], timeout: 5, allowFailure: true)
        for value in found.output.split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(value), pid > 1, pid != getpid() else { continue }
            let command = try Runtime.command("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3, allowFailure: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownedCreate = command.contains("--label dev.okdocker.app=\(record.id) ") && command.contains("--label dev.okdocker.scope=\(scope) ")
            let buildExecutable = command.contains("/container/plugins/build/bin/build ") || command.contains("/container build ")
            let ownedBuild = buildExecutable && command.contains("--tag okdocker.local/\(record.project)/") && ownedCreate
            let ownedStart = ownedNames.contains { command == "/usr/local/bin/container start \($0)" || command == "/opt/homebrew/bin/container start \($0)" }
            if ownedCreate || ownedBuild || ownedStart { guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw Problem("未确认该应用启动客户端已取消") } }
        }
    }
    static func killCurrent(_ record: AppRecord) throws {
        let all = try containers(record)
        let ids = try all.filter(active).map(id)
        if !ids.isEmpty { _ = try cli(["kill", "--signal", "KILL"] + ids, allowFailure: true) }
        let deadline = Date().addingTimeInterval(12)
        while try containers(record).contains(where: active) {
            guard Date() < deadline else { throw Problem("Apple 容器尚未全部停止，未确认强制关闭") }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
    static func remove(_ record: AppRecord) throws {
        let all = try containers(record)
        guard !all.contains(where: active) else { throw Problem("先强制关闭应用，再移除登记") }
        let ids = try all.map(id)
        if !ids.isEmpty { _ = try cli(["delete"] + ids) }
        if try network(record, create: false) != nil { _ = try cli(["network", "delete", record.project]) }
    }
}
