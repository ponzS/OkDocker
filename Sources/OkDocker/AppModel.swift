import AppKit
import SwiftUI
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    @Published var apps: [AppRecord] = []
    @Published var observations: [String: Observation] = [:]
    @Published var busy: Set<String> = []
    @Published var lanStatuses: [String: LANStatus] = [:]
    private var lanRestoreHandled: Set<String> = []
    @Published var engineText = "检查 Apple container…"
    @Published var engineReady = false
    @Published var context = AppleRuntime.context
    @Published var message = ""
    @Published var search = ""
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var refreshing = false
    var changed: (() -> Void)?
    var showWindow: (() -> Void)?
    private var timer: Timer?
    private var autostartHandled: Set<String> = []
    private var startupRequested = false
    private var loginEngineAttempted = false

    init() {
        if let registry = try? Runtime.load() { apps = registry.apps; context = registry.context }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    var filtered: [AppRecord] { apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var runningCount: Int { observations.values.filter { $0.running > 0 }.count }
    func icon(_ app: AppRecord) -> NSImage? {
        // UI rendering must not synchronously read Desktop/external-volume files:
        // a TCC prompt or offline volume could block the first window forever.
        // Cache only the explicitly approved icon at import time.
        guard app.icon != nil else { return nil }
        return NSImage(contentsOf: Runtime.appDirectory(app).appendingPathComponent("approved-icon"))
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true
        let selected = context
        Task {
            let result = await Task.detached(priority: .utility) { () -> (Registry?, String?, [String: Observation], [String: LANStatus]) in
                let registry = try? Runtime.load()
                var version: String?; var observations: [String: Observation] = [:]
                do { version = try Runtime.engine(selected) } catch { version = nil }
                for app in registry?.apps ?? [] {
                    do { observations[app.id] = try Runtime.observe(app) }
                    catch { observations[app.id] = Observation(state: app.context == AppleRuntime.context ? "engineUnavailable" : "migrationRequired", detail: app.context == AppleRuntime.context ? "Apple container 未就绪" : "旧 Docker 登记；未确认旧实例状态，请显式迁移到 Apple container", containers: 0, running: 0, healthy: nil) }
                }
                let lan = Dictionary(uniqueKeysWithValues: (registry?.apps ?? []).map { ($0.id, LANAccess.status($0)) })
                return (registry, version, observations, lan)
            }.value
            if let registry = result.0 { apps = registry.apps }
            observations = result.2; lanStatuses = result.3
            engineReady = result.1 != nil
            engineText = result.1.map { selected == AppleRuntime.context ? "Apple container \($0) · 每容器独立轻量 VM" : "旧 Docker \($0) · \(selected)" } ?? (selected == AppleRuntime.context ? "Apple container 未就绪" : "旧 Docker 未就绪 · 请迁移")
            refreshing = false; loginStatus = SMAppService.mainApp.status; changed?()
            // One attempt per enabled app, only after its engine is ready. Failed
            // starts are visible; no endless rebuild/retry loop.
            for app in apps where app.context == AppleRuntime.context && app.autoStart && !autostartHandled.contains(app.id) && !busy.contains(app.id) {
                if let state = observations[app.id], state.state != "engineUnavailable" {
                    autostartHandled.insert(app.id)
                    if state.running == 0 { start(app) }
                }
            }
            if !engineReady && apps.contains(where: { $0.autoStart && $0.context == context }) && !loginEngineAttempted {
                loginEngineAttempted = true
                if context.hasPrefix("colima-") { message = "等待 Colima：请先按 README 正常启动运行时；GUI 冷启动目录共享尚未通过验收" }
                else { startEngine() }
            }
            for app in apps where app.lanAccess == true && !lanRestoreHandled.contains(app.id) && (observations[app.id]?.running ?? 0) > 0 {
                lanRestoreHandled.insert(app.id)
                perform("lan-" + app.id) { try LANAccess.ensure(app); return "局域网入口已恢复" }
            }
            checkHTTP()
        }
    }
    private func checkHTTP() {
        let candidates = apps.filter { observations[$0.id]?.state == "running" }
        Task {
            for app in candidates {
                guard let url = await Task.detached(priority: .utility, operation: { try? Runtime.approved(app).manifest.backend.url }).value else { continue }
                var request = URLRequest(url: url); request.timeoutInterval = 3; request.cachePolicy = .reloadIgnoringLocalCacheData
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let ok = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
                    if var observation = observations[app.id], observation.state == "running" {
                        observation.healthy = ok
                        observation.detail = ok ? "服务可访问 · \(observation.running) 个容器" : "容器运行，但服务端返回错误"
                        if !ok { observation.state = "unhealthy" }
                        observations[app.id] = observation
                    }
                } catch {
                    if var observation = observations[app.id], observation.state == "running" {
                        observation.state = "starting"; observation.detail = "容器运行，服务端暂未可访问"; observation.healthy = false
                        observations[app.id] = observation
                    }
                }
            }
            changed?()
        }
    }
    func perform(_ id: String, _ work: @escaping @Sendable () throws -> String) {
        guard !busy.contains(id) else { return }; busy.insert(id); changed?()
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busy.remove(id)
            switch result { case .success(let text): message = text; case .failure(let error): message = error.localizedDescription; if error.localizedDescription != "启动已取消" { alert(error.localizedDescription) } }
            refresh(); changed?()
        }
    }
    func start(_ app: AppRecord) {
        guard !busy.contains(app.id + "-stop") else { return }
        if app.context != AppleRuntime.context { migrate(app); return }
        perform(app.id) { try Runtime.start(app) }
    }
    func migrate(_ app: AppRecord) {
        let a = NSAlert(); a.messageText = "迁移「\(app.name)」到 Apple container？"
        a.informativeText = "请先确认旧 Docker 实例已停止；引擎不可连接不代表容器已停止。这里只迁移登记，不搬运数据、不构建或启动服务，自动启动保持关闭。旧资源不会自动删除。\n\n切换部署前请先备份，并正常关闭原服务，避免多个实例同时写入同一份数据。"
        a.addButton(withTitle: "已确认旧实例停止，迁移登记"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform(app.id) { try Runtime.migrateToApple(app, confirmOldStopped: true) }
    }
    func close(_ app: AppRecord) {
        let alert = NSAlert(); alert.messageText = "强制关闭「\(app.name)」？"
        alert.informativeText = "将立即向这个应用的全部容器发送 SIGKILL，不等待任务收尾。未完成的任务和数据写入可能中断。不会删除文件、停止其他应用或关闭共享 ADB。"
        alert.alertStyle = .warning; alert.addButton(withTitle: "强制关闭"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(app.id + "-stop") { try Runtime.forceStop(app) }
    }
    func open(_ app: AppRecord, backend: Bool = false) {
        perform("browser-" + app.id) {
            let m = try Runtime.approved(app).manifest
            let url = backend ? m.backend.url : m.frontend.url
            Task { @MainActor in if !NSWorkspace.shared.open(url) { self.alert("无法打开默认浏览器") } }
            return "已请求从浏览器打开 \(app.name)"
        }
    }
    func reveal(_ app: AppRecord) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.root) }
    func importPanel() {
        let panel = NSOpenPanel(); panel.title = "添加容器应用"; panel.message = "选择应用文件夹或其中的 okdocker.json。导入只登记，不会立即构建或启动。"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        do {
            let v = try validate(root: root)
            let alert = NSAlert(); alert.messageText = "添加「\(v.manifest.name)」"
            alert.informativeText = "授权目录：\(v.root.path)\n前端：\(v.manifest.frontend.url.absoluteString)\n服务端：\(v.manifest.backend.url.absoluteString)\n安卓手机：\(v.manifest.hostAndroidDevices == true ? "允许访问全部已授权安卓设备（含后续接入）" : "不注入共享通道")\n\n只导入你信任的应用。安卓开关不是恶意程序的网络/设备沙箱；运行时网络权限需要单独验收。镜像/构建会运行其代码；默认仅挂载本应用目录。登录自动启动保持关闭。"
            alert.addButton(withTitle: "确认导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let context = context
            perform("import") { _ = try Runtime.importApp(root, context: context); return "已添加 \(v.manifest.name)，点击图标启动" }
        } catch { alert(error.localizedDescription) }
    }
    func setAuto(_ app: AppRecord, enabled: Bool) {
        do {
            guard !enabled || app.context == AppleRuntime.context else { throw Problem("请先确认旧实例停止并迁移到 Apple container，再启用登录自动启动") }
            if enabled {
                if ![SMAppService.Status.enabled, .requiresApproval].contains(SMAppService.mainApp.status) { try SMAppService.mainApp.register() }
                loginStatus = SMAppService.mainApp.status
                guard loginStatus == .enabled else {
                    SMAppService.openSystemSettingsLoginItems()
                    throw Problem("请先在系统设置中允许 OkDocker 登录启动，然后重新开启此应用的开关。")
                }
            }
            try Runtime.autostart(app, enabled: enabled)
            if enabled { autostartHandled.insert(app.id) }
            message = enabled ? "已开启登录后自动启动" : "已关闭登录自动启动"
            refresh()
        } catch { alert(error.localizedDescription) }
    }
    func setLAN(_ app: AppRecord, enabled: Bool) {
        if enabled {
            let prompt = NSAlert(); prompt.messageText = "允许「\(app.name)」被局域网访问？"
            prompt.informativeText = "局域网内的设备将能访问此应用的前端和服务端，认证由应用提供。许可开启期间，后续接入的私有 Wi-Fi/以太网也会自动绑定，只在可信网络开启。不开放 ADB 端口、不改系统防火墙，容器无需重建。"
            prompt.addButton(withTitle: "允许局域网访问"); prompt.addButton(withTitle: "取消")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }
        }
        perform("lan-" + app.id) { try LANAccess.set(app, enabled: enabled) }
    }
    func copyLAN(_ app: AppRecord) {
        Task {
            do {
                let text = try await Task.detached(priority: .utility) {
                    let m = try Runtime.approved(app).manifest
                    let state = LANAccess.status(try Runtime.record(app.id))
                    let urls = state.addresses.compactMap { LANAccess.url(m.frontend, host: $0)?.absoluteString }
                    guard !urls.isEmpty else { throw Problem(state.error.isEmpty ? "局域网入口尚未就绪，请在应用设置中开启" : state.error) }
                    return urls.joined(separator: "\n")
                }.value
                copyText(text, message: "已复制局域网前端地址")
            } catch { alert(error.localizedDescription) }
        }
    }
    func copyText(_ text: String, message: String) {
        do { try ConfigurationRules.copy(text); self.message = message }
        catch { alert(error.localizedDescription) }
    }
    func copyRules() {
        Task {
            do {
                let text = try await Task.detached(priority: .utility) { try ConfigurationRules.text() }.value
                copyText(text, message: "已复制完整配置规则，可粘贴给 AI")
            } catch { alert(error.localizedDescription) }
        }
    }
    func registerLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else {
                try SMAppService.mainApp.unregister()
                for app in apps where app.autoStart { try Runtime.autostart(app, enabled: false) }
            }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            refresh()
        } catch { alert(error.localizedDescription) }
    }
    func chooseContext(_ value: String) {
        do { try Runtime.localContext(value); try Runtime.transaction { $0.context = value }; context = value; refresh() } catch { alert(error.localizedDescription) }
    }
    func startEngine() {
        if context == AppleRuntime.context {
            guard !startupRequested else { return }; startupRequested = true
            perform("engine") {
                defer { Task { @MainActor in self.startupRequested = false } }
                return try AppleRuntime.startEngine()
            }
            return
        }
        if context.hasPrefix("colima-") {
            alert("本机从 GUI 冷启动 Colima 后出现过目录共享阻塞，这条路径尚未通过验收，已暂时禁用。\n\n请按 README 在终端正常启动对应 profile 并批准系统访问请求，例如：\ncolima start --profile okdocker --activate=false\n\n启动器会自动检查引擎并启动已开启登录启动的应用。不关闭 TCC，也不自动替你批准系统权限。")
            return
        }
        guard !startupRequested else { return }; startupRequested = true
        let context = context
        perform("engine") {
            defer { Task { @MainActor in self.startupRequested = false } }
            let bundle = context.contains("orbstack") ? "/Applications/OrbStack.app" : "/Applications/Docker.app"
            guard FileManager.default.fileExists(atPath: bundle) else { throw Problem("未找到对应运行时。请按 README 安装，或在设置中选择已有的 Docker context。") }
            _ = try Runtime.command("/usr/bin/open", [bundle])
            return "已打开 Docker 运行时，等待引擎就绪"
        }
    }
    func remove(_ app: AppRecord) {
        let alert = NSAlert(); alert.messageText = "从 OkDocker 移除「\(app.name)」？"; alert.informativeText = "移除登记和已停止的容器。宿主应用目录及其挂载数据保留，但容器内未挂载的可写层会丢失；请先备份。"; alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(app.id) { try Runtime.remove(app); return "已移除登记，数据保留" }
    }
    func alert(_ text: String) { let a = NSAlert(); a.messageText = "OkDocker"; a.informativeText = text; a.addButton(withTitle: "知道了"); a.runModal() }
    func logs(_ app: AppRecord) {
        perform(app.id) {
            let ids = try Runtime.ids(app)
            guard let first = ids.first else { throw Problem("没有可查看的容器日志") }
            let output = app.context == AppleRuntime.context ? try AppleRuntime.cli(["logs", "-n", "200", first], allowFailure: true).output : try Runtime.docker(app.context, ["logs", "--tail", "200", first], allowFailure: true).output
            let file = Runtime.appDirectory(app).appendingPathComponent("container.log")
            try Runtime.write(Data(output.utf8), to: file)
            Task { @MainActor in NSWorkspace.shared.open(file) }
            return "已打开最近 200 行日志（可能包含应用自己的敏感内容，请勿随意分享）"
        }
    }
}
