import Foundation
import Darwin

// Official CLI adapter only. Runtime owns approvals, operation locks and cancellation.
// No Docker daemon/context, shell expansion, imported Compose, or VM reimplementation.
enum AppleRuntime {
    static let context = "apple-container"
    static let testedVersion = "1.7.1"
    static var scope: String { digest(Data(Runtime.support.standardizedFileURL.path.utf8)) }
    static func checkPlatform() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { throw Problem(tr("Apple container 需要 macOS 26 或更新版本")) }
        #if !arch(arm64)
        throw Problem(tr("Apple container 后端仅支持 Apple Silicon；不使用隐式 x86 模拟"))
        #endif
    }
    static func cli(_ args: [String], timeout: TimeInterval = 30, allowFailure: Bool = false, cwd: URL? = nil, liveLog: URL? = nil) throws -> CommandResult {
        try checkPlatform()
        return try Runtime.command(Runtime.find("container"), args, timeout: timeout, cwd: cwd, allowFailure: allowFailure, liveLog: liveLog)
    }
    static func array(_ output: String) throws -> [[String: Any]] {
        guard let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { throw Problem(tr("Apple container 返回了无法识别的数据；未确认实际状态")) }
        return value
    }
    static func engine() throws -> String {
        let output = try cli(["system", "status", "--format", "json"], timeout: 10).output
        guard let status = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], status["status"] as? String == "running" else { throw Problem(tr("Apple container 尚未启动，请点击“启动运行时”")) }
        let version = (status["server"] as? [String: Any])?["version"] as? String ?? "unknown"
        guard version == testedVersion else { throw Problem(L("Apple container \(version) is installed; this build is adapted and validated only for \(testedVersion). Install that signed official release.", "当前 Apple container \(version)，本版仅适配并验收 \(testedVersion)。请安装对应官方签名版本。")) }
        return version
    }
    static func startEngine() throws -> String {
        _ = try cli(["system", "start", "--enable-kernel-install", "--timeout", "180"], timeout: 240)
        return L("Apple container \(try engine()) is running. Starting an app still checks real files and HTTP I/O", "Apple container \(try engine()) 服务已启动；应用启动后还会检查实际文件与 HTTP I/O")
    }
    static func labels(_ record: AppRecord) -> [String: String] { ["dev.okdocker.app": record.id, "dev.okdocker.scope": scope] }
    static func owns(_ object: [String: Any], record: AppRecord) -> Bool {
        guard let config = object["configuration"] as? [String: Any], let actual = config["labels"] as? [String: String] else { return false }
        return labels(record).allSatisfy { actual[$0.key] == $0.value }
    }
    static func ownedContainers(_ record: AppRecord) throws -> [[String: Any]] {
        try array(cli(["list", "--all", "--format", "json"]).output).filter { owns($0, record: record) }
    }
    static func metadata(_ object: [String: Any]) -> [String: String] { (object["configuration"] as? [String: Any])?["labels"] as? [String: String] ?? [:] }
    static func service(_ object: [String: Any]) -> String? { metadata(object)["dev.okdocker.service"] }
    static let relayExecutable = "/run/okdocker/adb-relay"
    static let relayConfigPath = "/run/okdocker/bridge.json"
    static let hostSocketMount = "/run/host-adb.sock"
    static let adbSocketEnv = "localfilesystem:/run/okdocker-adb.sock"
    struct AndroidGuest {
        var directory: String
        var hostSocket: String
        var command: [String]
    }
    static func isLegacyPeer(_ object: [String: Any], record: AppRecord) -> Bool {
        let mounts = (object["configuration"] as? [String: Any])?["mounts"] as? [[String: Any]] ?? []
        return mounts.contains { ($0["destination"] as? String) == "/run/okdocker-adb.sock" && ($0["source"] as? String) == AndroidBridge.peerSocket(record).path }
    }
    static func containers(_ record: AppRecord) throws -> [[String: Any]] {
        let latest = (try? Runtime.record(record.id)) ?? record
        let deployment = latest.deployment ?? "legacy"
        let owned = try ownedContainers(record)
        let selected = owned.filter { service($0) != "okdocker-adb" && (metadata($0)["dev.okdocker.deployment"] ?? "legacy") == deployment }
        let legacy = selected.contains { isLegacyPeer($0, record: record) }
        return owned.filter {
            if service($0) == "okdocker-adb" { return legacy }
            return (metadata($0)["dev.okdocker.deployment"] ?? "legacy") == deployment
        }
    }
    static func id(_ object: [String: Any]) throws -> String {
        guard let value = (object["configuration"] as? [String: Any])?["id"] as? String, !value.isEmpty else { throw Problem(tr("Apple container 缺少容器 ID")) }; return value
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
        if running == 0 { return Observation(state: "stopped", detail: L("Apple containers are stopped. Mounted data and existing writable layers are kept", "Apple 容器已停止，挂载数据和现有容器可写层保留"), containers: all.count, running: 0, healthy: nil) }
        if let expected, all.count != expected { return Observation(state: "partial", detail: L("Apple containers missing: \(all.count)/\(expected)", "Apple 容器缺失：\(all.count)/\(expected)"), containers: all.count, running: running, healthy: false) }
        return Observation(state: started == all.count ? "running" : "partial", detail: L("Apple lightweight VMs: \(started)/\(all.count) containers running", "Apple 轻量 VM：\(started)/\(all.count) 个容器运行"), containers: all.count, running: running, healthy: nil)
    }
    static func name(_ record: AppRecord, _ service: String) -> String {
        guard service != "okdocker-adb", let deployment = record.deployment else { return record.project + "-" + service }
        // Keep upstream container/hostname IDs <=63 bytes even for 41-byte service names.
        return record.project + "-" + digest(Data("\(deployment)/\(service)".utf8)).prefix(40)
    }
    static func mountArgument(source: String, target: String, readOnly: Bool) throws -> String {
        guard ![source, target].contains(where: { $0.contains(",") || $0.contains("\0") || $0.contains("\n") }) else { throw Problem(tr("Apple mount 参数不能无歧义表示含逗号、换行或 NUL 的路径，请先重命名")) }
        return "type=bind,source=\(source),target=\(target)" + (readOnly ? ",readonly" : "")
    }
    static func imageProcess(_ image: String, override: [String]?) throws -> [String] {
        let objects = try array(cli(["image", "inspect", image], timeout: 60).output)
        guard let variants = objects.first?["variants"] as? [[String: Any]],
              let imageConfig = (variants.first?["config"] as? [String: Any])?["config"] as? [String: Any] else {
            throw Problem(L("Cannot read the image command; the container was not created", tr("无法读取镜像命令，未创建容器")))
        }
        let entry = imageConfig["Entrypoint"] as? [String] ?? []
        let command = override ?? (imageConfig["Cmd"] as? [String] ?? [])
        let process = entry + command
        guard !process.isEmpty, process.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw Problem(L("The image has no command to run after the ADB relay", tr("镜像没有可在 ADB 转发之后执行的命令"))) }
        return process
    }
    static func guestDirectory(_ record: AppRecord) -> URL { Runtime.appDirectory(record).appendingPathComponent("android-guest") }
    static func prepareGuest(_ record: AppRecord, refreshExecutable: Bool = true) throws -> AndroidGuest {
        let bridge = try AndroidBridge.launchUnix(record)
        guard let token = bridge["token"] as? String, !token.isEmpty else { throw Problem(L("Android bridge token is missing", tr("安卓桥令牌缺失"))) }
        let directory = guestDirectory(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try Runtime.json(["socket": hostSocketMount, "token": token, "listenSocket": "/run/okdocker-adb.sock"], to: directory.appendingPathComponent("bridge.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("bridge.json").path)
        if refreshExecutable {
            // Only refresh before a stopped container starts. Never replace the
            // executable under a running workload. Keep its mount and layer.
            let binary = directory.appendingPathComponent("adb-relay")
            try Runtime.write(Data(contentsOf: Runtime.resources.appendingPathComponent("Android/adb-relay")), to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return AndroidGuest(directory: directory.path, hostSocket: AndroidBridge.unixSocket(record).path, command: [])
    }
    static func requireAndroidTransport(_ container: String) throws {
        let deadline = Date().addingTimeInterval(12)
        repeat {
            let result = try cli(["exec", container, relayExecutable, "--check", relayConfigPath], timeout: 8, allowFailure: true)
            if result.code == 0 { return }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        throw Problem(L("The container is running, but its ADB transport failed verification. Restart this app with the updated OkDocker; no containers or data were deleted.", "容器已启动，但 ADB 通道校验失败。请使用更新后的 OkDocker 关闭并重新启动此应用；未删除容器或数据。"))
    }
    static func stopUnusedSidecar(_ record: AppRecord) throws {
        let ids = try ownedContainers(record).filter { service($0) == "okdocker-adb" && active($0) }.map { try id($0) }
        if !ids.isEmpty { _ = try cli(["stop", "--time", "5"] + ids, timeout: 30, allowFailure: true) }
    }
    static func createArguments(_ record: AppRecord, service: String, spec: ServiceSpec, validated v: Validated, image: String, extraEnvironment: [String: String] = [:], androidGuest: AndroidGuest? = nil, legacyPeer: Bool = false) throws -> [String] {
        var args = ["create", "--name", name(record, service), "--platform", "linux/arm64", "--network", record.project, "--init", "--cap-drop", "NET_RAW"]
        var metadata = labels(record).merging(["dev.okdocker.manifest": v.hash, "dev.okdocker.service": service, "dev.okdocker.deployment": service == "okdocker-adb" ? "shared" : record.deployment ?? "legacy"], uniquingKeysWith: { _, b in b })
        if service != "okdocker-adb", let version = v.manifest.version { metadata["dev.okdocker.version"] = version }
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) { args += ["--label", "\(key)=\(value)"] }
        for mount in spec.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] {
            args += ["--mount", try mountArgument(source: contained(mount.source, root: v.root, directory: true).path, target: mount.target, readOnly: mount.readOnly ?? false)]
        }
        if let wd = spec.workingDirectory { args += ["--workdir", wd] }
        for (key, value) in (spec.environment ?? [:]).merging(extraEnvironment, uniquingKeysWith: { _, b in b }).sorted(by: { $0.key < $1.key }) {
            guard !value.contains("\0") else { throw Problem(tr("环境变量不能包含 NUL")) }
            args += ["--env", "\(key)=\(value)"]
        }
        for port in Set([v.manifest.frontend, v.manifest.backend].filter { $0.service == service }.map { "127.0.0.1:\($0.hostPort):\($0.containerPort)/tcp" }).sorted() { args += ["--publish", port] }
        if legacyPeer && service == v.manifest.backend.service {
            args += ["--volume", AndroidBridge.peerSocket(record).path + ":/run/okdocker-adb.sock"]
        }
        if let androidGuest, service == v.manifest.backend.service {
            guard !androidGuest.command.isEmpty else { throw Problem(L("ADB relay has no application command", tr("ADB 转发缺少应用命令"))) }
            args += ["--entrypoint", relayExecutable, "--mount", try mountArgument(source: androidGuest.directory, target: "/run/okdocker", readOnly: true), "--volume", androidGuest.hostSocket + ":" + hostSocketMount]
            return args + ["--", image, "--config", relayConfigPath, "--"] + androidGuest.command
        }
        return args + ["--", image] + (spec.command ?? [])
    }
    static func network(_ record: AppRecord, create: Bool) throws -> [String: Any]? {
        let networks = try array(cli(["network", "list", "--format", "json"]).output)
        if let found = networks.first(where: { ($0["configuration"] as? [String: Any])?["name"] as? String == record.project }) {
            guard owns(found, record: record) else { throw Problem(tr("同名网络不属于该应用，拒绝接管")) }
            return found
        }
        if !create { return nil }
        var args = ["network", "create"]
        for (key, value) in labels(record).sorted(by: { $0.key < $1.key }) { args += ["--label", "\(key)=\(value)"] }
        _ = try cli(args + [record.project])
        return try network(record, create: false)
    }
    static func image(_ record: AppRecord, service: String, spec: ServiceSpec, root: URL, fresh: Bool = false) throws -> String {
        if let build = spec.build {
            let suffix = service == "okdocker-adb" ? "" : record.deployment.map { "-" + $0 } ?? ""
            let image = "okdocker.local/\(record.project)/\(service):\(scope.prefix(12))\(suffix)"
            let directory = try contained(build.context, root: root, directory: true)
            let dockerfile = try contained(build.dockerfile, root: directory, directory: false)
            Startup.phase(record, L("Building \(service); reusing dependency cache", "正在构建 \(service)，复用依赖缓存"))
            let result = try BuildRecipe.withDockerfile(build, context: directory, dockerfile: dockerfile, scratch: Runtime.appDirectory(record)) { recipe in
                try cli(["build"] + (fresh && build.script != nil ? ["--build-arg", "OKDOCKER_BUILD_ID=\(record.deployment ?? UUID().uuidString)"] : []) + ["--platform", "linux/arm64", "--progress", "plain", "--tag", image, "--label", "dev.okdocker.app=\(record.id)", "--label", "dev.okdocker.scope=\(scope)", "--file", recipe.path, directory.path], timeout: 1800, cwd: directory, liveLog: Startup.log(record))
            }
            try Runtime.write(Data(result.output.utf8), to: Runtime.appDirectory(record).appendingPathComponent("last-build.log"))
            return image
        }
        guard let image = spec.image else { throw Problem(tr("服务缺少镜像")) }
        if try fresh || cli(["image", "inspect", image], allowFailure: true).code != 0 { _ = try cli(["image", "pull", "--platform", "linux/arm64", "--", image], timeout: 1800) }
        return image
    }
    // Audit the actual, stopped container BEFORE starting it. Fail closed when the
    // upstream JSON format changes; never trust a successful create alone.
    static func audit(_ object: [String: Any], record: AppRecord, v: Validated, service: String, spec: ServiceSpec, privateMount: String? = nil, androidGuest: AndroidGuest? = nil, legacyPeer: Bool = false) throws {
        guard owns(object, record: record), let c = object["configuration"] as? [String: Any],
              (privateMount != nil ? (c["labels"] as? [String: String])?["dev.okdocker.service"] == "okdocker-adb" : (c["labels"] as? [String: String])?["dev.okdocker.manifest"] == v.hash),
              c["ssh"] as? Bool != true, c["rosetta"] as? Bool != true, c["virtualization"] as? Bool != true,
              (c["capAdd"] as? [String] ?? []).isEmpty,
              (c["platform"] as? [String: Any])?["architecture"] as? String == "arm64",
              (c["platform"] as? [String: Any])?["os"] as? String == "linux",
              c["runtimeHandler"] as? String == "container-runtime-linux", c["useInit"] as? Bool == true,
              !(Set(c["capDrop"] as? [String] ?? []).intersection(["CAP_NET_RAW", "ALL"]).isEmpty) else { throw Problem(tr("Apple 容器实际权限或配置摘要不符合本次授权")) }
        if privateMount != nil, !(c["capDrop"] as? [String] ?? []).contains("ALL") { throw Problem(tr("ADB sidecar 必须移除全部 capabilities")) }
        let mounts = c["mounts"] as? [[String: Any]] ?? []
        var expected: Set<String> = []
        if let privateMount {
            expected.insert(privateMount + "|/run/okdocker|true")
            expected.insert(AndroidBridge.unixSocket(record).path + "|/run/host-adb.sock|false")
        }
        else {
            for m in spec.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] { expected.insert(try contained(m.source, root: v.root).path + "|" + m.target + "|\(m.readOnly ?? false)") }
        }
        if let androidGuest, privateMount == nil, service == v.manifest.backend.service {
            expected.insert(androidGuest.directory + "|/run/okdocker|true")
            expected.insert(androidGuest.hostSocket + "|" + hostSocketMount + "|false")
        } else if legacyPeer && privateMount == nil && service == v.manifest.backend.service {
            expected.insert(AndroidBridge.peerSocket(record).path + "|/run/okdocker-adb.sock|false")
        }
        let sockets = c["publishedSockets"] as? [[String: Any]] ?? []
        if privateMount != nil {
            guard sockets.count == 1, sockets[0]["hostPath"] as? String == AndroidBridge.peerSocket(record).path, sockets[0]["containerPath"] as? String == "/run/adb-client.sock" else { throw Problem(tr("ADB sidecar socket 转发不符合授权")) }
        } else { guard sockets.isEmpty else { throw Problem(L("The application publishes an unapproved socket", tr("应用包含未授权 socket 发布"))) } }
        if let androidGuest, service == v.manifest.backend.service {
            let process = (c["initProcess"] as? [String: Any]) ?? [:]
            let arguments = process["arguments"] as? [String] ?? []
            guard process["executable"] as? String == relayExecutable, Array(arguments.prefix(3)) == ["--config", relayConfigPath, "--"], Array(arguments.dropFirst(3)) == androidGuest.command else {
                throw Problem(L("ADB relay entrypoint does not match the approved in-container transport", tr("ADB 转发入口与已批准的容器内通道不符")))
            }
        }
        guard mounts.allSatisfy({ ($0["type"] as? [String: Any])?["virtiofs"] != nil }) else { throw Problem(tr("Apple 容器包含未授权类型的挂载")) }
        let actual = Set(mounts.map { m in "\(m["source"] as? String ?? "?")|\(m["destination"] as? String ?? "?")|\((m["options"] as? [String] ?? []).contains("ro"))" })
        guard actual == expected, mounts.count == expected.count else { throw Problem(tr("Apple 容器实际挂载与授权不一致")) }
        let networks = c["networks"] as? [[String: Any]] ?? []
        guard networks.count == 1, networks[0]["network"] as? String == record.project else { throw Problem(tr("Apple 容器接入了未授权网络")) }
        let allowed = Set([v.manifest.frontend, v.manifest.backend].filter { $0.service == service }.map { "\($0.hostPort)|\($0.containerPort)" })
        let ports = c["publishedPorts"] as? [[String: Any]] ?? []
        guard ports.allSatisfy({ p in p["hostAddress"] as? String == "127.0.0.1" && (p["count"] as? Int ?? 1) == 1 && (p["proto"] as? String == "tcp") && allowed.contains("\(p["hostPort"] as? Int ?? -1)|\(p["containerPort"] as? Int ?? -1)") }), ports.count == allowed.count else { throw Problem(tr("Apple 容器端口不符合 loopback 授权")) }
    }
    static func inspect(_ name: String) throws -> [String: Any] {
        guard let c = try array(cli(["inspect", name]).output).first else { throw Problem(tr("创建后未观察到 Apple 容器")) }; return c
    }
    static func guest(from object: [String: Any], record: AppRecord) -> AndroidGuest? {
        let process = ((object["configuration"] as? [String: Any])?["initProcess"] as? [String: Any]) ?? [:]
        guard process["executable"] as? String == relayExecutable else { return nil }
        let arguments = process["arguments"] as? [String] ?? []
        guard Array(arguments.prefix(3)) == ["--config", relayConfigPath, "--"] else { return nil }
        return AndroidGuest(directory: guestDirectory(record).path, hostSocket: AndroidBridge.unixSocket(record).path, command: Array(arguments.dropFirst(3)))
    }
    static func start(_ record: AppRecord) throws -> String {
        let v = try Runtime.approved(record); _ = try engine()
        let baseline = (try? Runtime.record(record.id)) ?? record
        if VersionDeployment.needsReplacement(baseline, desired: v, existing: try containers(record)) {
            return try VersionDeployment.replace(baseline, desired: v)
        }
        for (service, spec) in v.manifest.services {
            _ = try createArguments(record, service: service, spec: spec, validated: v, image: spec.image ?? "okdocker-preflight")
        }
        var existing = try containers(record)
        let backendName = v.manifest.backend.service
        let backend = existing.first { service($0) == backendName }
        let legacyAndroid = v.manifest.hostAndroidDevices == true && (backend.map { isLegacyPeer($0, record: record) } ?? false)
        var expected = Set(v.manifest.services.keys)
        if legacyAndroid { expected.insert("okdocker-adb") }
        for object in existing {
            guard let key = service(object) else { throw Problem(L("An existing container has no service label and will not be reused", tr("现有容器缺少服务标签，拒绝复用"))) }
            if let spec = v.manifest.services[key] {
                let relay = (!legacyAndroid && key == backendName) ? guest(from: object, record: record) : nil
                if v.manifest.hostAndroidDevices == true && key == backendName && !legacyAndroid && relay == nil {
                    throw Problem(L("The existing container does not use the in-container ADB relay. It was not deleted. Back up its data, remove the registration, and import again.", tr("现有容器没有使用容器内 ADB 转发。未删除旧容器。请备份数据后移除登记并重新导入。")))
                }
                try audit(object, record: record, v: v, service: key, spec: spec, androidGuest: relay, legacyPeer: legacyAndroid && key == backendName)
            } else if key == "okdocker-adb", legacyAndroid {
                try audit(object, record: record, v: v, service: key, spec: ServiceSpec(mounts: []), privateMount: Runtime.appDirectory(record).appendingPathComponent("android-config").path)
            } else { throw Problem(L("An existing container is not one of the approved services", tr("现有容器不属于本次授权的服务"))) }
        }
        let current = try observe(record)
        if current.state == "running", current.containers == expected.count {
            if v.manifest.hostAndroidDevices == true && !legacyAndroid {
                // A live VM says nothing about ADB. Recreate a missing host
                // bridge and publish its token, then verify the in-guest owner
                // and real host protocol without restarting the application.
                _ = try prepareGuest(record, refreshExecutable: false)
                try requireAndroidTransport(name(record, backendName))
            }
            return L("\(record.name) is already running", "\(record.name) 已在运行")
        }
        if current.running > 0 && record.deployment == nil { throw Problem(L("The application is only partly running. Force-stop it and try again", tr("应用部分运行，请先强制关闭后重试"))) }
        try LANAccess.stop(record)
        let runningServices = Set(existing.filter { ($0["status"] as? [String: Any])?["state"] as? String == "running" }.compactMap(service))
        let pendingPorts = Set([v.manifest.frontend, v.manifest.backend].filter { !runningServices.contains($0.service) }.map(\.hostPort))
        for port in pendingPorts { try Runtime.requireFreePort(port) }
        if !existing.isEmpty {
            guard existing.allSatisfy({ service($0) == "okdocker-adb" || metadata($0)["dev.okdocker.manifest"] == v.hash }) else { throw Problem(L("Existing containers use an older configuration. They were not deleted, so their writable layers remain. Back up container data, remove the registration, and import again. The application directory on the Mac is kept.", tr("现有容器使用旧配置。为保护容器可写层，未自动删除。请先备份容器内数据，移除旧登记后重新导入；宿主应用目录保留。"))) }
        }
        _ = try network(record, create: true)
        var images: [String: String] = [:]
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) where !existing.contains(where: { metadata($0)["dev.okdocker.service"] == service }) {
            images[service] = try image(record, service: service, spec: spec, root: v.root)
        }
        try VersionDeployment.recheck(record, desired: v)
        var adbAddress: String?
        var prepared: AndroidGuest?
        if v.manifest.hostAndroidDevices == true {
            if legacyAndroid { adbAddress = try startAndroid(record, v: v, existing: existing) }
            else { prepared = try prepareGuest(record, refreshExecutable: !runningServices.contains(backendName)); adbAddress = adbSocketEnv }
        }
        for port in pendingPorts { try Runtime.requireFreePort(port) }
        try VersionDeployment.recheck(record, desired: v)
        try Runtime.json(["count": expected.count, "manifestHash": v.hash], to: Runtime.appDirectory(record).appendingPathComponent("apple-plan.json"))
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) {
            let containerName = name(record, service)
            let old = existing.first { metadata($0)["dev.okdocker.service"] == service }
            var serviceGuest: AndroidGuest?
            if old == nil {
                var env: [String: String] = [:]
                if service == backendName, let adbAddress { env["ADB_SERVER_SOCKET"] = adbAddress }
                if var created = prepared, service == backendName {
                    created.command = try imageProcess(images[service]!, override: spec.command)
                    serviceGuest = created
                }
                _ = try cli(createArguments(record, service: service, spec: spec, validated: v, image: images[service]!, extraEnvironment: env, androidGuest: serviceGuest), timeout: 120)
            } else if adbAddress != nil && service == backendName {
                let env = (((old?["configuration"] as? [String: Any])?["initProcess"] as? [String: Any])?["environment"] as? [String]) ?? []
                guard env.contains("ADB_SERVER_SOCKET=\(adbAddress!)") else { throw Problem(L("The ADB transport does not match the existing container. The old container was not deleted. Back up its data, remove the registration, and import again.", tr("ADB 通道配置与现有容器不符；未删除旧容器。请备份容器内数据后移除登记并重新导入。"))) }
            }
            let created = try inspect(containerName)
            let audited = serviceGuest ?? ((service == backendName && !legacyAndroid) ? guest(from: created, record: record) : nil)
            try audit(created, record: record, v: v, service: service, spec: spec, androidGuest: audited, legacyPeer: legacyAndroid && service == backendName)
            if (created["status"] as? [String: Any])?["state"] as? String != "running" { _ = try cli(["start", containerName], timeout: 120) }
            if v.manifest.hostAndroidDevices == true && !legacyAndroid && service == backendName {
                try requireAndroidTransport(containerName)
            }
        }
        existing = try containers(record)
        guard existing.count == expected.count, existing.allSatisfy({ ($0["status"] as? [String: Any])?["state"] as? String == "running" }) else { throw Problem(L("Not every Apple container is running. Check the actual state or force-stop the application", tr("未观察到全部 Apple 容器运行；请查看实际状态或强制关闭"))) }
        return L("Started \(record.name) · Apple container", "已启动 \(record.name) · Apple container")
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
        if (try inspect(containerName)["status"] as? [String: Any])?["state"] as? String != "running" { _ = try cli(["start", containerName], timeout: 120) }
        return "localfilesystem:/run/okdocker-adb.sock"
    }
    struct DeploymentInfo: Encodable {
        var id: String; var service: String?; var version: String?; var deployment: String; var state: String; var selected: Bool
    }
    static func deployments(_ record: AppRecord) throws -> [DeploymentInfo] {
        let latest = try Runtime.record(record.id)
        return try ownedContainers(record).filter { service($0) != "okdocker-adb" }.map {
            let labels = ($0["configuration"] as? [String: Any])?["labels"] as? [String: String] ?? [:]
            let revision = labels["dev.okdocker.deployment"] ?? "legacy"
            return DeploymentInfo(id: try id($0), service: service($0), version: labels["dev.okdocker.version"], deployment: revision, state: ($0["status"] as? [String: Any])?["state"] as? String ?? "unknown", selected: revision == (latest.deployment ?? "legacy"))
        }
    }
    static func cancelLaunchers(_ record: AppRecord) throws {
        let ownedNames = Set(try ownedContainers(record).map(id))
        let found = try Runtime.command("/usr/bin/pgrep", ["-u", String(getuid()), "-f", "(^|/)(container (create|start|build|image pull|network create)|build) "], timeout: 5, allowFailure: true)
        for value in found.output.split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(value), pid > 1, pid != getpid() else { continue }
            let command = try Runtime.command("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3, allowFailure: true).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownedCreate = command.contains("--label dev.okdocker.app=\(record.id) ") && command.contains("--label dev.okdocker.scope=\(scope) ")
            let buildExecutable = command.contains("/container/plugins/build/bin/build ") || command.contains("/container build ")
            let ownedBuild = buildExecutable && command.contains("--tag okdocker.local/\(record.project)/") && ownedCreate
            let ownedStart = ownedNames.contains { command == "/usr/local/bin/container start \($0)" || command == "/opt/homebrew/bin/container start \($0)" }
            if ownedCreate || ownedBuild || ownedStart { guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw Problem(tr("未确认该应用启动客户端已取消")) } }
        }
    }
    static func killCurrent(_ record: AppRecord) throws {
        let all = try ownedContainers(record)
        let ids = try all.filter(active).map(id)
        if !ids.isEmpty { _ = try cli(["kill", "--signal", "KILL"] + ids, allowFailure: true) }
        let deadline = Date().addingTimeInterval(12)
        while try ownedContainers(record).contains(where: active) {
            guard Date() < deadline else { throw Problem(tr("Apple 容器尚未全部停止，未确认强制关闭")) }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
    static func remove(_ record: AppRecord) throws {
        let all = try ownedContainers(record)
        guard !all.contains(where: active) else { throw Problem(tr("先强制关闭应用，再移除登记")) }
        let ids = try all.map(id)
        if !ids.isEmpty { _ = try cli(["delete"] + ids) }
        if try network(record, create: false) != nil { _ = try cli(["network", "delete", record.project]) }
    }
}
