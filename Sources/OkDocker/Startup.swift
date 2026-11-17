import Foundation
import Darwin

/// The start lock, rather than a GUI-only flag or stale JSON, is authoritative.
enum Startup {
    static func log(_ app: AppRecord) -> URL { Runtime.appDirectory(app).appendingPathComponent("startup.log") }
    static func active(_ app: AppRecord) -> Bool {
        let fd = open(Runtime.appDirectory(app).appendingPathComponent("start.lock").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
    static func begin(_ app: AppRecord) throws {
        try Runtime.write(Data(), to: log(app))
        phase(app, L("Checking configuration and application version", "检查配置和应用版本"))
    }
    static func phase(_ app: AppRecord, _ detail: String) {
        try? Runtime.json(["detail": detail, "pid": getpid()], to: Runtime.appDirectory(app).appendingPathComponent("startup-phase.json"))
        guard let handle = try? FileHandle(forWritingTo: log(app)) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n[\(ISO8601DateFormatter().string(from: Date()))] \(detail)\n".utf8))
    }
    static func observation(_ app: AppRecord) -> Observation? {
        guard active(app) else { return nil }
        let data = try? Data(contentsOf: Runtime.appDirectory(app).appendingPathComponent("startup-phase.json"))
        let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return Observation(state: "starting", detail: value?["detail"] as? String ?? L("Starting or building; open logs for progress", "正在启动或构建，可查看日志了解进度"), containers: 0, running: 0, healthy: nil)
    }
    static func tail(_ file: URL, limit: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - UInt64(limit) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
