import Foundation
import Darwin

struct CommandResult { var code: Int32; var output: String }
struct Runtime {
    @TaskLocal static var cancellation: URL?
    static var support: URL {
        if let path = ProcessInfo.processInfo.environment["OKDOCKER_SUPPORT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OkDocker")
    }
    static var resources: URL {
        if let p = ProcessInfo.processInfo.environment["OKDOCKER_RESOURCES"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func json(_ value: Any, to url: URL) throws { try write(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: url) }
    static func find(_ name: String) throws -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin", "/Applications/OrbStack.app/Contents/MacOS/xbin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for dir in paths where FileManager.default.isExecutableFile(atPath: dir + "/" + name) { return dir + "/" + name }
        throw Problem(name == "container" ? L("Apple container is not installed. Install the signed 1.7.1 package from Apple's official Releases, then start the runtime.", "未安装 Apple container。请从 Apple 官方 Releases 安装 1.7.1 签名安装包，再点击启动运行时。") : L("\(name) was not found. The legacy Docker backend needs its original CLI; new apps should use Apple container.", "未找到 \(name)。旧 Docker 后端需要原来的 CLI；新应用请使用 Apple container。"))
    }
    static func command(_ program: String, _ args: [String], timeout: TimeInterval = 60, cwd: URL? = nil, allowFailure: Bool = false) throws -> CommandResult {
        try prepare()
        if let cancellation, FileManager.default.fileExists(atPath: cancellation.path) { throw Problem(tr("启动已取消")) }
        let temp = support.appendingPathComponent("command-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: program); process.arguments = args
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        for key in Array(env.keys) where key.hasPrefix("COMPOSE_") || key.hasPrefix("CONTAINER_") || ["BUILDKIT_HOST", "BUILDX_BUILDER", "BUILDX_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"].contains(key) { env.removeValue(forKey: key) }
        env["COMPOSE_ANSI"] = "never"; env["DOCKER_CLI_HINTS"] = "false"
        // Never let inherited endpoint variables override an explicitly selected local context.
        env.removeValue(forKey: "DOCKER_HOST"); env.removeValue(forKey: "DOCKER_CONTEXT")
        process.environment = env
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while process.isRunning && Date() < deadline {
            if let cancellation, FileManager.default.fileExists(atPath: cancellation.path) { cancelled = true; break }
            Thread.sleep(forTimeInterval: 0.08)
        }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if cancelled { throw Problem(tr("启动已取消")) }
            throw Problem(L("The operation timed out after \(Int(timeout)) seconds. Check the runtime's actual state; this does not prove the container has stopped.", "操作超时（\(Int(timeout)) 秒）。请查看运行时的实际状态，不能据此认定容器已停止。"))
        }
        process.waitUntilExit(); try handle.synchronize()
        let output = String(data: (try? Data(contentsOf: temp)) ?? Data(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && !allowFailure { throw Problem(String(output.suffix(5000)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return CommandResult(code: process.terminationStatus, output: output)
    }
    static func docker(_ context: String, _ args: [String], timeout: TimeInterval = 60, allowFailure: Bool = false) throws -> CommandResult {
        try command(find("docker"), ["--context", context] + args, timeout: timeout, allowFailure: allowFailure)
    }
    static func compose(_ record: AppRecord, _ args: [String], timeout: TimeInterval = 60) throws -> CommandResult {
        let common = ["--context", record.context, "--project-name", record.project, "--project-directory", record.root, "--env-file", "/dev/null", "--file", composeFile(record).path]
        if let executable = try? find("docker-compose") { return try command(executable, common + args, timeout: timeout, cwd: URL(fileURLWithPath: record.root)) }
        return try command(find("docker"), ["--context", record.context, "compose"] + Array(common.dropFirst(2)) + args, timeout: timeout, cwd: URL(fileURLWithPath: record.root))
    }
    static func localContext(_ name: String) throws {
        if name == AppleRuntime.context { try AppleRuntime.checkPlatform(); return }
        let result = try docker(name, ["context", "inspect", name])
        let data = Data(result.output.utf8)
        guard let contexts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let endpoint = (contexts.first?["Endpoints"] as? [String: [String: Any]])?["docker"]?["Host"] as? String, endpoint.hasPrefix("unix://") else { throw Problem(tr("只支持本机 Unix socket Docker context，不能将宿主路径发往远端引擎")) }
    }
    static func engine(_ context: String) throws -> String { if context == AppleRuntime.context { return try AppleRuntime.engine() }; try localContext(context); return try docker(context, ["info", "--format", "{{.ServerVersion}}"], timeout: 12).output.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func appDirectory(_ record: AppRecord) -> URL { support.appendingPathComponent("apps/\(record.id)") }
    static func composeFile(_ record: AppRecord) -> URL { appDirectory(record).appendingPathComponent("compose.json") }
    static func load() throws -> Registry {
        try prepare()
        let file = support.appendingPathComponent("registry.json")
        if !FileManager.default.fileExists(atPath: file.path) { return Registry() }
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
    }
    // One-time, backed-up default change. Never silently move a running app.
    static func upgradeBackendDefault() throws {
        if try load().schemaVersion < 2 {
            try transaction { registry in
                guard registry.schemaVersion < 2 else { return }
                let backup = support.appendingPathComponent("registry-before-apple.json")
                guard !FileManager.default.fileExists(atPath: backup.path) else { throw Problem(tr("已有 Apple 迁移备份但注册表版本仍旧，请人工检查；不会覆盖备份")) }
                try write(JSONEncoder().encode(registry), to: backup)
                registry.schemaVersion = 2; registry.context = AppleRuntime.context
                for i in registry.apps.indices where registry.apps[i].context != AppleRuntime.context { registry.apps[i].autoStart = false }
            }
        }
        // Additive 0.3 metadata keeps registry format 2, with a pre-upgrade backup.
        let backup = support.appendingPathComponent("registry-before-versions.json")
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("registry.json").path), !FileManager.default.fileExists(atPath: backup.path) {
            try transaction { registry in
                if !FileManager.default.fileExists(atPath: backup.path) { try write(JSONEncoder().encode(registry), to: backup) }
            }
        }
    }
    static func migrateToApple(_ record: AppRecord, confirmOldStopped: Bool) throws -> String {
        guard record.context != AppleRuntime.context else { return tr("已经使用 Apple container") }
        guard confirmOldStopped else { throw Problem(tr("迁移前须确认旧 Docker 实例已停止。这里只迁移登记，不搬运数据、不启动服务。")) }
        try FileManager.default.createDirectory(at: appDirectory(record), withIntermediateDirectories: true)
        let fd = open(appDirectory(record).appendingPathComponent("start.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(tr("无法锁定迁移")) }; defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Problem(tr("旧后端正在启动，请先取消启动并确认停止")) }
        if let running = try? observe(record).running, running > 0 { throw Problem(tr("旧 Docker 实例仍在运行，先正常收尾并关闭后再迁移")) }
        _ = try approved(record)
        try transaction { registry in
            guard let i = registry.apps.firstIndex(where: { $0.id == record.id }), registry.apps[i].context == record.context else { throw Problem(tr("应用登记已改变，请刷新")) }
            try write(JSONEncoder().encode(record), to: appDirectory(record).appendingPathComponent("before-apple.json"))
            registry.apps[i].context = AppleRuntime.context; registry.apps[i].autoStart = false
            registry.context = AppleRuntime.context
        }
        return tr("已迁移登记到 Apple container；未启动服务，登录自动启动保持关闭")
    }
    static func transaction<T>(_ body: (inout Registry) throws -> T) throws -> T {
        try prepare()
        let lock = open(support.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Problem(tr("无法锁定应用注册表")) }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Problem(tr("注册表正在使用")) }
        var registry = try load()
        let result = try body(&registry)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(registry), to: support.appendingPathComponent("registry.json"))
        return result
    }
    static func importApp(_ root: URL, context: String) throws -> AppRecord {
        let v = try validate(root: root); try localContext(context)
        return try transaction { registry in
            if let old = registry.apps.first(where: { $0.root == v.root.path && $0.context == context }) {
                guard try observe(old).running == 0 else { throw Problem(tr("更新配置前请先关闭这个应用")) }
                var updated = old; updated.name = v.manifest.name; updated.icon = v.manifest.icon; updated.manifestHash = v.hash; updated.approvalHash = try v.approvalHash(); updated.manifestVersion = v.manifest.version
                registry.apps[registry.apps.firstIndex(where: { $0.id == old.id })!] = updated
                if let icon = v.icon { try write(Data(contentsOf: icon), to: appDirectory(updated).appendingPathComponent("approved-icon")) }
                return updated
            }
            let id = UUID().uuidString.lowercased()
            var record = AppRecord(id: id, root: v.root.path, name: v.manifest.name, icon: v.manifest.icon, project: "okdocker-" + String(id.prefix(12)), context: context, autoStart: false, manifestHash: v.hash, importedAt: Date())
            record.approvalHash = try v.approvalHash(); record.manifestVersion = v.manifest.version
            if let icon = v.icon { try write(Data(contentsOf: icon), to: appDirectory(record).appendingPathComponent("approved-icon")) }
            registry.apps.append(record); registry.context = context
            return record
        }
    }
    static func record(_ id: String) throws -> AppRecord {
        guard let r = try load().apps.first(where: { $0.id == id || $0.project == id }) else { throw Problem(tr("未找到已导入的应用")) }; return r
    }
    static func approved(_ record: AppRecord) throws -> Validated {
        let v = try validate(root: URL(fileURLWithPath: record.root))
        if v.hash == record.manifestHash {
            if record.approvalHash == nil {
                let hash = try v.approvalHash()
                try transaction { registry in
                    if let i = registry.apps.firstIndex(where: { $0.id == record.id && $0.manifestHash == record.manifestHash }), registry.apps[i].approvalHash == nil {
                        registry.apps[i].approvalHash = hash; registry.apps[i].manifestVersion = v.manifest.version
                    }
                }
            }
            return v
        }
        guard record.context == AppleRuntime.context, let approved = record.approvalHash, approved == (try v.approvalHash()) else {
            throw Problem(tr("配置已改变或旧登记缺少授权基线。请先关闭并重新导入确认；只有 version 变化可以自动重新部署。"))
        }
        // Formatting-only changes do not invalidate the existing container seal.
        if v.manifest.version == record.manifestVersion { return Validated(root: v.root, manifest: v.manifest, hash: record.manifestHash, icon: v.icon) }
        return v
    }
    static func ids(_ record: AppRecord, runningOnly: Bool = false) throws -> [String] {
        if record.context == AppleRuntime.context { return try AppleRuntime.containers(record).filter { !runningOnly || AppleRuntime.active($0) }.compactMap { ($0["configuration"] as? [String: Any])?["id"] as? String } }
        let output = try docker(record.context, ["ps", runningOnly ? "-q" : "-aq", "--filter", "label=com.docker.compose.project=\(record.project)"], timeout: 15).output
        return output.split(whereSeparator: \.isWhitespace).map(String.init)
    }
    static func inspect(_ record: AppRecord) throws -> [[String: Any]] {
        let ids = try ids(record)
        if ids.isEmpty { return [] }
        let result = try docker(record.context, ["inspect"] + ids, timeout: 15)
        return try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] ?? []
    }
    static func observe(_ record: AppRecord) throws -> Observation {
        if record.context == AppleRuntime.context { return try AppleRuntime.observe(record) }
        let containers = try inspect(record)
        if containers.isEmpty { return Observation(state: "stopped", detail: tr("尚未启动或已移除容器"), containers: 0, running: 0, healthy: nil) }
        let running = containers.filter { ($0["State"] as? [String: Any])?["Running"] as? Bool == true }.count
        if running == 0 { return Observation(state: "stopped", detail: tr("全部容器已停止，数据保留"), containers: containers.count, running: 0, healthy: nil) }
        if running != containers.count { return Observation(state: "partial", detail: L("\(running)/\(containers.count) containers running", "\(running)/\(containers.count) 个容器运行"), containers: containers.count, running: running, healthy: false) }
        let states = containers.compactMap { (($0["State"] as? [String: Any])?["Health"] as? [String: Any])?["Status"] as? String }
        if states.contains("unhealthy") { return Observation(state: "unhealthy", detail: tr("Docker 健康检查失败"), containers: containers.count, running: running, healthy: false) }
        if states.contains("starting") { return Observation(state: "starting", detail: tr("健康检查正在启动"), containers: containers.count, running: running, healthy: nil) }
        return Observation(state: "running", detail: tr("容器运行中，正在检查服务"), containers: containers.count, running: running, healthy: nil)
    }
    // Compose treats $ as interpolation even in JSON; preserve container arguments literally.
    static func escaped(_ value: Any) -> Any {
        if let s = value as? String { return s.replacingOccurrences(of: "$", with: "$$") }
        if let a = value as? [Any] { return a.map(escaped) }
        if let d = value as? [String: Any] { return d.mapValues(escaped) }
        return value
    }
    static func generate(_ record: AppRecord, validated v: Validated, bridge: [String: Any]? = nil) throws {
        guard !v.manifest.services.values.contains(where: { $0.build?.script != nil }) else { throw Problem(tr("build.script 仅支持 Apple container 后端，请先显式迁移登记")) }
        var services: [String: Any] = [:]
        for (name, s) in v.manifest.services {
            var service: [String: Any] = ["restart": "no", "init": true, "security_opt": ["no-new-privileges:true"], "labels": ["dev.okdocker.app": record.id]]
            if let image = s.image { service["image"] = image }
            if let b = s.build { service["build"] = ["context": try contained(b.context, root: v.root).path, "dockerfile": b.dockerfile] }
            service["volumes"] = try (s.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)]).map { mount -> [String: Any] in ["type": "bind", "source": try contained(mount.source, root: v.root).path, "target": mount.target, "read_only": mount.readOnly ?? false, "bind": ["create_host_path": false]] }
            if let cmd = s.command { service["command"] = cmd }
            if let wd = s.workingDirectory { service["working_dir"] = wd }
            var environment = s.environment ?? [:]
            if bridge != nil && name == v.manifest.backend.service { environment["ADB_SERVER_SOCKET"] = "tcp:okdocker-adb:5037"; service["depends_on"] = ["okdocker-adb"] }
            service["environment"] = environment
            let endpoints = [v.manifest.frontend, v.manifest.backend].filter { $0.service == name }
            let ports = Set(endpoints.map { "127.0.0.1:\($0.hostPort):\($0.containerPort)" }).sorted()
            if !ports.isEmpty { service["ports"] = ports }
            services[name] = service
        }
        if let bridge {
            let directory = appDirectory(record).appendingPathComponent("android-client")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["Dockerfile", "client.py"] {
                let source = resources.appendingPathComponent("Android/\(name)")
                try write(Data(contentsOf: source), to: directory.appendingPathComponent(name))
            }
            let configuration = appDirectory(record).appendingPathComponent("bridge-client.json")
            try json(bridge, to: configuration)
            services["okdocker-adb"] = ["build": ["context": directory.path], "restart": "no", "init": true,
                "read_only": true, "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
                "volumes": [["type": "bind", "source": configuration.path, "target": "/run/bridge.json", "read_only": true]],
                "labels": ["dev.okdocker.app": record.id]]
        }
        try json(escaped(["services": services]), to: composeFile(record))
    }
    // Audit the exact expanded Compose model before any image build/container creation.
    // Disabling implicit .env loading is important: the manifest is the authority.
    static func auditExpanded(_ record: AppRecord, validated v: Validated, android: Bool) throws {
        let output = try compose(record, ["config", "--format", "json"]).output
        guard let config = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], let services = config["services"] as? [String: [String: Any]] else { throw Problem(tr("无法验证展开后的 Compose")) }
        let names = Set(v.manifest.services.keys).union(android ? ["okdocker-adb"] : [])
        guard Set(services.keys) == names else { throw Problem(tr("展开后的服务与授权配置不一致")) }
        for (name, service) in services {
            let fields: Set<String> = ["build", "image", "command", "entrypoint", "environment", "init", "labels", "networks", "ports", "restart", "security_opt", "volumes", "working_dir", "depends_on", "read_only", "cap_drop"]
            guard Set(service.keys).isSubset(of: fields), service["restart"] as? String == "no" else { throw Problem(L("The expanded configuration contains an unapproved capability: \(name)", "展开配置包含未授权能力：\(name)")) }
            if let entrypoint = service["entrypoint"], !(entrypoint is NSNull) { throw Problem(tr("不允许覆盖镜像入口")) }
            var allowed: Set<String> = []
            if name == "okdocker-adb" {
                allowed.insert(appDirectory(record).appendingPathComponent("bridge-client.json").path + "|/run/bridge.json")
            } else if let spec = v.manifest.services[name] {
                for mount in spec.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] { allowed.insert(try contained(mount.source, root: v.root).path + "|" + mount.target) }
            }
            for mount in service["volumes"] as? [[String: Any]] ?? [] {
                guard mount["type"] as? String == "bind", let source = mount["source"] as? String, let target = mount["target"] as? String, allowed.contains(source + "|" + target) else { throw Problem(tr("展开配置包含未授权挂载")) }
            }
            for port in service["ports"] as? [[String: Any]] ?? [] {
                guard port["host_ip"] as? String == "127.0.0.1", port["protocol"] as? String == "tcp" else { throw Problem(tr("端口仅允许发布到本机 loopback")) }
            }
            if let build = service["build"] as? [String: Any], let context = build["context"] as? String {
                if name == "okdocker-adb" { guard context == appDirectory(record).appendingPathComponent("android-client").path else { throw Problem(tr("非法桥构建目录")) } }
                else { guard let spec = v.manifest.services[name]?.build, context == (try contained(spec.context, root: v.root).path) else { throw Problem(tr("构建目录未获授权")) } }
            }
        }
        let networks = config["networks"] as? [String: [String: Any]] ?? [:]
        guard Set(networks.keys).isSubset(of: ["default"]), !networks.values.contains(where: { $0["external"] as? Bool == true }) else { throw Problem(tr("不允许加入外部 Docker 网络")) }
        try write(Data(output.utf8), to: appDirectory(record).appendingPathComponent("expanded-compose.json"))
    }
    static func start(_ record: AppRecord) throws -> String {
        let latest = try self.record(record.id)
        guard latest.context == record.context, latest.manifestHash == record.manifestHash, latest.deployment == record.deployment else { throw Problem(tr("登记已改变，请刷新后再启动")) }
        try FileManager.default.createDirectory(at: appDirectory(record), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let gate = open(appDirectory(record).appendingPathComponent("stop.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard gate >= 0 else { throw Problem(tr("无法锁定操作")) }; defer { close(gate) }
        guard flock(gate, LOCK_SH | LOCK_NB) == 0 else { throw Problem(tr("应用正在关闭，请稍后再启动")) }
        let fd = open(appDirectory(record).appendingPathComponent("start.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(tr("无法锁定启动操作")) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Problem(tr("应用已经在启动")) }
        let cancel = appDirectory(record).appendingPathComponent("stop.request")
        try? FileManager.default.removeItem(at: cancel)
        flock(gate, LOCK_UN)
        return try $cancellation.withValue(cancel) {
            do {
                let text = try startImpl(record)
                if (try? self.record(record.id).lanAccess) == true {
                    do { try LANAccess.ensure(record) }
                    catch { return text + tr("；局域网入口未就绪：") + error.localizedDescription }
                }
                return text
            }
            catch {
                if FileManager.default.fileExists(atPath: cancel.path) {
                    try? $cancellation.withValue(nil) { try killCurrent(record); AndroidBridge.stop(record) }
                    throw Problem(tr("启动已取消"))
                }
                throw error
            }
        }
    }
    static func requireFreePort(_ port: Int) throws {
        // Darwin SO_REUSEADDR can permit a specific-address bind next to a
        // wildcard listener. A successful bind alone is NOT an occupancy test.
        let listeners = try command("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"], timeout: 5, allowFailure: true)
        guard listeners.code == 1 && listeners.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem(L("Host port \(port) is busy or could not be confirmed free. Stop the original service or change the configuration. Other programs will not be killed.", "宿主端口 \(port) 已占用或无法确认空闲。请先停止原服务或修改配置；不会替你杀掉其他程序。")) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Problem(tr("无法检查宿主端口")) }; defer { close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 1) == 0 else { throw Problem(L("Host port \(port) is in use. Stop the original service or change the configuration. Other programs will not be killed.", "宿主端口 \(port) 已占用。请先停止原服务或修改配置；不会替你杀掉其他程序。")) }
    }
    private static func startImpl(_ record: AppRecord) throws -> String {
        if record.context == AppleRuntime.context { return try AppleRuntime.start(record) }
        let v = try approved(record); _ = try engine(record.context)
        let existing = try observe(record)
        if existing.running > 0 {
            guard existing.state == "running" else { throw Problem(tr("应用部分运行或异常，请先强制关闭后再启动")) }
            return L("\(record.name) is already running", "\(record.name) 已在运行")
        }
        for port in Set([v.manifest.frontend.hostPort, v.manifest.backend.hostPort]) { try requireFreePort(port) }
        // The kernel/Docker own the port truth. Do not read other imported
        // projects here: an offline volume or pending TCC grant for an unrelated
        // app must not block this app's start.
        var bridge: [String: Any]?
        if v.manifest.hostAndroidDevices == true { bridge = try AndroidBridge.launch(record) }
        do {
            try generate(record, validated: v, bridge: bridge)
            try auditExpanded(record, validated: v, android: bridge != nil)
            // Do slow builds/pulls before the final port check. A wildcard host
            // service must not be shadowed after a long image build.
            if bridge != nil || v.manifest.services.values.contains(where: { $0.build != nil }) {
                let build = try compose(record, ["build"], timeout: 1800)
                try write(Data(build.output.utf8), to: appDirectory(record).appendingPathComponent("last-build.log"))
            }
            for image in Set(v.manifest.services.values.compactMap(\.image)) {
                if try docker(record.context, ["image", "inspect", image], allowFailure: true).code != 0 { _ = try docker(record.context, ["pull", image], timeout: 1800) }
            }
            for port in Set([v.manifest.frontend.hostPort, v.manifest.backend.hostPort]) { try requireFreePort(port) }
            let output = try compose(record, ["up", "-d", "--no-build", "--pull", "never", "--remove-orphans"], timeout: 120).output
            try write(Data(output.utf8), to: appDirectory(record).appendingPathComponent("last-start.log"))
            let observed = try observe(record)
            guard observed.running > 0 else { throw Problem(tr("启动命令结束，但没有观察到运行中的容器。请查看日志。")) }
            return L("Started \(record.name)", "已启动 \(record.name)")
        } catch { if (try? ids(record, runningOnly: true).isEmpty) == true { AndroidBridge.stop(record) }; throw error }
    }
    private static func cancelLaunchers(_ record: AppRecord) throws {
        if record.context == AppleRuntime.context { try AppleRuntime.cancelLaunchers(record); return }
        // Revoke an in-flight Compose client even if its UI/CLI parent died.
        // Both the unique project and its private compose path must match.
        let pattern = "(^|/)(docker-compose|docker) .*--project-name " + record.project + "( |$)"
        let result = try command("/usr/bin/pgrep", ["-u", String(getuid()), "-f", pattern], timeout: 5, allowFailure: true)
        for value in result.output.split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(value), pid > 1, pid != getpid() else { continue }
            let info = try command("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3, allowFailure: true)
            guard info.output.contains("--project-name " + record.project + " "), info.output.contains(composeFile(record).path) else { continue }
            guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw Problem(tr("无法取消该应用的启动客户端，未确认关闭")) }
        }
    }
    private static func killCurrent(_ record: AppRecord) throws {
        if record.context == AppleRuntime.context { try AppleRuntime.killCurrent(record); return }
        let running = try ids(record, runningOnly: true)
        if !running.isEmpty { _ = try docker(record.context, ["kill", "--signal", "KILL"] + running, allowFailure: true) }
        guard try ids(record, runningOnly: true).isEmpty else { throw Problem(tr("仍有运行中的容器，未确认关闭")) }
    }
    static func forceStop(_ record: AppRecord) throws -> String {
        try FileManager.default.createDirectory(at: appDirectory(record), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let gate = open(appDirectory(record).appendingPathComponent("stop.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard gate >= 0 else { throw Problem(tr("无法锁定关闭操作")) }; defer { flock(gate, LOCK_UN); close(gate) }
        guard flock(gate, LOCK_EX) == 0 else { throw Problem(tr("无法锁定关闭操作")) }
        try write(Data("cancel\n".utf8), to: appDirectory(record).appendingPathComponent("stop.request"))
        try LANAccess.stop(record)
        try cancelLaunchers(record)
        try killCurrent(record)
        let fd = open(appDirectory(record).appendingPathComponent("start.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem(tr("已终止当前容器，但无法确认启动操作已取消")) }
        defer { flock(fd, LOCK_UN); close(fd) }
        let deadline = Date().addingTimeInterval(8)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw Problem(tr("当前容器已被终止，但启动取消仍未确认，请重试关闭")) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try killCurrent(record)
        AndroidBridge.stop(record)
        return L("Force-stopped \(record.name). Application files and data were kept", "已强制关闭 \(record.name)，保留应用文件与数据")
    }
    static func remove(_ record: AppRecord) throws {
        guard try ids(record, runningOnly: true).isEmpty else { throw Problem(tr("请先关闭应用，再从启动器移除")) }
        try LANAccess.stop(record)
        if record.context == AppleRuntime.context {
            try AppleRuntime.remove(record)
            AndroidBridge.stop(record)
            try transaction { $0.apps.removeAll { $0.id == record.id } }
            return
        }
        guard try ids(record, runningOnly: true).isEmpty else { throw Problem(tr("请先关闭应用，再从启动器移除")) }
        let existing = try ids(record)
        if !existing.isEmpty { _ = try docker(record.context, ["rm"] + existing) }
        let networks = try docker(record.context, ["network", "ls", "-q", "--filter", "label=com.docker.compose.project=\(record.project)"]).output.split(whereSeparator: \.isWhitespace).map(String.init)
        if !networks.isEmpty { _ = try docker(record.context, ["network", "rm"] + networks) }
        AndroidBridge.stop(record)
        try transaction { $0.apps.removeAll { $0.id == record.id } }
    }
    static func autostart(_ record: AppRecord, enabled: Bool) throws {
        try transaction { registry in
            guard let index = registry.apps.firstIndex(where: { $0.id == record.id }) else { throw Problem(tr("应用已移除")) }
            registry.apps[index].autoStart = enabled
        }
    }
}
