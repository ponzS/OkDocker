import Foundation
import CryptoKit

struct Problem: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ message: String) { self.message = message } }
struct Endpoint: Codable, Equatable {
    var service: String
    var directory: String
    var path: String
    var hostPort: Int
    var containerPort: Int
    var url: URL { URL(string: "http://127.0.0.1:\(hostPort)\(path)")! }
}
struct Mount: Codable { var source: String; var target: String; var readOnly: Bool? }
struct BuildSpec: Codable { var context: String; var dockerfile: String; var script: String? = nil }
struct ServiceSpec: Codable {
    var image: String?
    var build: BuildSpec?
    var command: [String]?
    var environment: [String: String]?
    var workingDirectory: String?
    var mounts: [Mount]?
}
struct Manifest: Codable {
    var schemaVersion: Int
    var id: String
    var name: String
    var icon: String?
    var frontend: Endpoint
    var backend: Endpoint
    var autoStart: Bool?
    var hostAndroidDevices: Bool?
    var services: [String: ServiceSpec]
    var version: String? = nil
}
struct AppRecord: Codable, Identifiable, Equatable {
    var id: String
    var root: String
    var name: String
    var icon: String?
    var project: String
    var context: String
    var autoStart: Bool
    var manifestHash: String
    var importedAt: Date
    // Runtime permission, never granted by an imported manifest. Missing = off.
    var lanAccess: Bool? = nil
    var approvalHash: String? = nil
    var manifestVersion: String? = nil
    var deployment: String? = nil
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.root == b.root && a.name == b.name && a.context == b.context && a.autoStart == b.autoStart && a.lanAccess == b.lanAccess && a.manifestHash == b.manifestHash && a.deployment == b.deployment && a.manifestVersion == b.manifestVersion }
}
struct Registry: Codable { var schemaVersion = 2; var context = AppleRuntime.context; var apps: [AppRecord] = [] }
struct Observation: Codable {
    var state: String
    var detail: String
    var containers: Int
    var running: Int
    var healthy: Bool?
    static let unknown = Observation(state: "unknown", detail: "等待实际状态", containers: 0, running: 0, healthy: nil)
    var title: String {
        switch state { case "migrationRequired": return "待迁移"; case "running": return "运行中"; case "unhealthy": return "服务异常"; case "partial": return "部分异常"; case "stopped": return "已关闭"; case "starting": return "启动中"; case "engineUnavailable": return "引擎未就绪"; default: return "等待检查" }
    }
}
struct Validated {
    let root: URL
    let manifest: Manifest
    let hash: String
    let icon: URL?
    // All declarative settings except the release version remain approved as a unit.
    func approvalHash() throws -> String {
        var value = manifest; value.version = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(value))
    }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// Resolve existing paths, including every symlink, before granting host access.
func contained(_ relative: String, root: URL, directory: Bool? = nil) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { throw Problem("路径必须相对于应用目录：\(relative)") }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let path = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard path.path == base.path || path.path.hasPrefix(base.path + "/") else { throw Problem("拒绝访问应用目录之外的路径：\(relative)") }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { throw Problem("路径不存在，请先创建：\(relative)") }
    if let directory, isDirectory.boolValue != directory { throw Problem("路径类型不正确：\(relative)") }
    let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
    guard values.isRegularFile == true || values.isDirectory == true else { throw Problem("不允许挂载 socket 或特殊设备文件：\(relative)") }
    return path
}
func validate(root input: URL) throws -> Validated {
    let root = input.standardizedFileURL.resolvingSymlinksInPath()
    let file = try contained("okdocker.json", root: root, directory: false)
    let data = try Data(contentsOf: file)
    guard data.count < 256 * 1024 else { throw Problem("配置文件过大（最多 256 KiB）") }
    let m: Manifest
    do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw Problem("okdocker.json 格式不正确：\(error.localizedDescription)") }
    guard m.schemaVersion == 1 else { throw Problem("不支持的配置版本，请使用 schemaVersion: 1") }
    if let version = m.version {
        guard version.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\\z", options: .regularExpression) != nil else { throw Problem("version 须为 1–64 位字母、数字或 . _ + -，例如 1.0.0") }
    }
    guard m.id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { throw Problem("id 只能使用小写字母、数字与连字符，且以字母开头") }
    guard !m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, m.name.count <= 60 else { throw Problem("应用昵称须为 1–60 个字符") }
    guard !m.services.isEmpty, m.services.count <= 16 else { throw Problem("请配置 1–16 个容器服务") }
    // Unknown fields are errors: never silently ignore a misspelled permission.
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let known: Set<String> = ["schemaVersion","version","id","name","icon","frontend","backend","autoStart","hostAndroidDevices","services"]
    guard Set(object.keys).isSubset(of: known) else { throw Problem("配置含未知字段：\(Set(object.keys).subtracting(known).sorted().joined(separator: ", "))") }
    for name in ["frontend", "backend"] {
        guard let raw = object[name] as? [String: Any], Set(raw.keys).isSubset(of: ["service", "directory", "path", "hostPort", "containerPort"]) else { throw Problem("端点含未知字段：\(name)") }
    }
    for endpoint in [m.frontend, m.backend] {
        guard m.services[endpoint.service] != nil else { throw Problem("前后端引用的服务不存在：\(endpoint.service)") }
        _ = try contained(endpoint.directory, root: root, directory: true)
        guard (1024...65535).contains(endpoint.hostPort), (1...65535).contains(endpoint.containerPort) else { throw Problem("宿主端口须为 1024–65535，容器端口须为 1–65535") }
        guard endpoint.path.hasPrefix("/"), !endpoint.path.hasPrefix("//"), !endpoint.path.contains("#"), !endpoint.path.contains("?"), !endpoint.path.contains("\\"), !endpoint.path.contains(where: { $0.isWhitespace }), let url = URL(string: "http://127.0.0.1:\(endpoint.hostPort)\(endpoint.path)"), url.host == "127.0.0.1" else { throw Problem("前后端 path 必须是本地 HTTP 路径，例如 / 或 /health") }
    }
    if m.frontend.hostPort == m.backend.hostPort && (m.frontend.service != m.backend.service || m.frontend.containerPort != m.backend.containerPort) { throw Problem("相同宿主端口不能发布给不同服务/容器端口") }
    for (name, s) in m.services {
        guard name.range(of: "^[a-z][a-z0-9-]{0,40}$", options: .regularExpression) != nil, name != "okdocker-adb" else { throw Problem("无效或保留的服务名：\(name)") }
        guard (s.image != nil) != (s.build != nil) else { throw Problem("服务 \(name) 必须且只能指定 image 或 build") }
        if let image = s.image { guard !image.isEmpty, !image.contains(where: { $0.isWhitespace }), !image.contains("$") else { throw Problem("镜像名无效") } }
        if let b = s.build {
            let context = try contained(b.context, root: root, directory: true)
            let dockerfile = try contained(b.dockerfile, root: context, directory: false)
            _ = try BuildRecipe.render(b, context: context, dockerfile: dockerfile)
        }
        if let cmd = s.command { guard !cmd.isEmpty, cmd.count <= 128, !cmd.contains(where: { $0.contains("\0") }) else { throw Problem("command 必须是容器内的程序与参数数组") } }
        if let working = s.workingDirectory { guard working.hasPrefix("/"), !working.contains("\0") else { throw Problem("workingDirectory 必须是容器内绝对目录") } }
        for mount in s.mounts ?? [Mount(source: ".", target: "/workspace", readOnly: false)] {
            _ = try contained(mount.source, root: root)
            guard mount.target.hasPrefix("/"), mount.target != "/", !mount.target.hasPrefix("/proc"), !mount.target.hasPrefix("/sys"), !mount.target.hasPrefix("/dev"), !mount.target.hasPrefix("/var/run"), !mount.target.contains(".."), !mount.target.contains("\0") else { throw Problem("不允许的容器挂载目标：\(mount.target)") }
        }
        let raw = (object["services"] as! [String: Any])[name] as! [String: Any]
        let fields: Set<String> = ["image","build","command","environment","workingDirectory","mounts"]
        guard Set(raw.keys).isSubset(of: fields) else { throw Problem("服务 \(name) 含未支持字段；不允许 privileged、devices、host network 或任意宿主命令") }
        if let build = raw["build"] as? [String: Any], !Set(build.keys).isSubset(of: ["context", "dockerfile", "script"]) { throw Problem("build 含未知字段") }
        for mount in raw["mounts"] as? [[String: Any]] ?? [] {
            guard Set(mount.keys).isSubset(of: ["source", "target", "readOnly"]) else { throw Problem("mounts 含未知字段") }
        }
        for key in (s.environment ?? [:]).keys { guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw Problem("无效环境变量名") } }
    }
    let icon = try m.icon.map { try contained($0, root: root, directory: false) }
    if let icon { guard ["png","jpg","jpeg","icns"].contains(icon.pathExtension.lowercased()), (try Data(contentsOf: icon)).count < 8 * 1024 * 1024 else { throw Problem("图标需为小于 8 MiB 的 PNG/JPG/ICNS") } }
    return Validated(root: root, manifest: m, hash: digest(data), icon: icon)
}
