import Foundation

// Release preparation/selection only. Runtime's existing start/stop locks and
// cancellation remain authoritative; AppleRuntime still starts/audits the VMs.
enum VersionDeployment {
    static func needsReplacement(_ record: AppRecord, desired v: Validated, existing: [[String: Any]]) -> Bool {
        if record.manifestVersion != v.manifest.version { return true }
        return existing.filter { AppleRuntime.service($0) != "okdocker-adb" }.contains {
            let labels = ($0["configuration"] as? [String: Any])?["labels"] as? [String: String]
            return labels?["dev.okdocker.version"] != v.manifest.version
        }
    }
    static func recheck(_ record: AppRecord, desired v: Validated) throws {
        let latest = try Runtime.record(record.id)
        guard latest.context == record.context, latest.root == record.root, latest.manifestHash == record.manifestHash, latest.deployment == record.deployment else { throw Problem("部署期间登记已改变，请刷新后重试") }
        let now = try Runtime.approved(latest)
        guard now.manifest.version == v.manifest.version, try now.approvalHash() == v.approvalHash() else { throw Problem("构建期间配置或 version 已改变，未继续部署；请重试") }
        if let cancel = Runtime.cancellation, FileManager.default.fileExists(atPath: cancel.path) { throw Problem("启动已取消") }
    }
    static func replace(_ record: AppRecord, desired v: Validated) throws -> String {
        var next = record
        next.deployment = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        next.manifestHash = v.hash; next.manifestVersion = v.manifest.version; next.approvalHash = try v.approvalHash()
        for (service, spec) in v.manifest.services {
            _ = try AppleRuntime.createArguments(next, service: service, spec: spec, validated: v, image: spec.image ?? "okdocker-preflight")
        }
        // Fresh tags and --no-cache --pull. A failed build never stops the old app.
        var images: [String: String] = [:]
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) {
            images[service] = try AppleRuntime.image(next, service: service, spec: spec, root: v.root, fresh: true)
        }
        try recheck(record, desired: v)
        _ = try AppleRuntime.network(next, create: true)
        let old = try AppleRuntime.containers(record)
        var adbAddress: String?
        if v.manifest.hostAndroidDevices == true { adbAddress = try AppleRuntime.startAndroid(next, v: v, existing: old) }
        // Prepare and audit stopped containers while the old deployment still runs.
        // Nothing can start these service VMs until their record is committed below.
        for (service, spec) in v.manifest.services.sorted(by: { $0.key < $1.key }) {
            let env = service == v.manifest.backend.service ? adbAddress.map { ["ADB_SERVER_SOCKET": $0] } ?? [:] : [:]
            _ = try AppleRuntime.cli(AppleRuntime.createArguments(next, service: service, spec: spec, validated: v, image: images[service]!, extraEnvironment: env), timeout: 120)
            try AppleRuntime.audit(AppleRuntime.inspect(AppleRuntime.name(next, service)), record: next, v: v, service: service, spec: spec)
        }
        try recheck(record, desired: v)
        let archive = Runtime.appDirectory(record).appendingPathComponent("deployments/\(UUID().uuidString).json")
        try Runtime.write(JSONEncoder().encode(record), to: archive)
        try LANAccess.stop(record)
        let activeOld = try old.filter { AppleRuntime.service($0) != "okdocker-adb" && AppleRuntime.active($0) }.map(AppleRuntime.id)
        if !activeOld.isEmpty { _ = try AppleRuntime.cli(["stop", "--time", "30"] + activeOld, timeout: 90) }
        let stillActive = try AppleRuntime.ownedContainers(record).filter { activeOld.contains((try? AppleRuntime.id($0)) ?? "") && AppleRuntime.active($0) }
        guard stillActive.isEmpty else { throw Problem("旧部署尚未停止，未启动新部署；旧容器及数据保留") }
        for port in Set([v.manifest.frontend.hostPort, v.manifest.backend.hostPort]) { try Runtime.requireFreePort(port) }
        try recheck(record, desired: v)
        try Runtime.transaction { registry in
            guard let i = registry.apps.firstIndex(where: { $0.id == record.id }), registry.apps[i].manifestHash == record.manifestHash, registry.apps[i].deployment == record.deployment else { throw Problem("登记已改变，未切换部署") }
            // Preserve permissions/preferences edited by the user during the build.
            registry.apps[i].deployment = next.deployment
            registry.apps[i].manifestHash = next.manifestHash
            registry.apps[i].manifestVersion = next.manifestVersion
            registry.apps[i].approvalHash = next.approvalHash
        }
        // Crash after commit? Next start resumes these audited, newly built containers.
        // Crash before commit? Prepared containers remain stopped, never late-started.
        let result = try AppleRuntime.start(next)
        return result + "；版本已更新为 \(v.manifest.version ?? "未设置")，旧部署已停止并保留"
    }
}
