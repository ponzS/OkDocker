import SwiftUI
import AppKit
import ServiceManagement

extension View {
    @ViewBuilder func liquid(_ radius: CGFloat = 22) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
struct StatusDot: View {
    let observation: Observation
    var color: Color { switch observation.state { case "running": return .green; case "starting": return .orange; case "unhealthy", "partial": return .red; default: return .secondary } }
    var body: some View { Circle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.35), radius: 4) }
}
struct AppArtwork: View {
    @ObservedObject var model: AppModel
    let app: AppRecord
    var size: CGFloat = 76
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(LinearGradient(colors: [.indigo.opacity(0.85), .cyan.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = model.icon(app) { Image(nsImage: image).resizable().scaledToFit().padding(size * 0.06) }
            else { Image(systemName: "shippingbox.fill").font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        .overlay(RoundedRectangle(cornerRadius: size * 0.25).stroke(.white.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.17), radius: 9, y: 5)
    }
}
struct AppActions: View {
    @ObservedObject var model: AppModel
    let app: AppRecord
    var settings: (() -> Void)?
    var body: some View {
        Button("从浏览器打开应用", systemImage: "safari") { model.open(app) }
        Button("打开服务端地址", systemImage: "network") { model.open(app, backend: true) }
        Button("复制局域网地址", systemImage: "doc.on.doc") { model.copyLAN(app) }.disabled(model.lanStatuses[app.id]?.addresses.isEmpty != false)
        Toggle("允许局域网访问", isOn: Binding(get: { model.apps.first(where: { $0.id == app.id })?.lanAccess == true }, set: { model.setLAN(app, enabled: $0) })).disabled(model.busy.contains("lan-" + app.id))
        Divider()
        Button(app.context == AppleRuntime.context ? "启动 / 检查版本更新" : "迁移到 Apple container…", systemImage: "play.fill") { model.start(app) }.disabled(model.busy.contains(app.id))
        Button("强制关闭应用", systemImage: "stop.fill", role: .destructive) { model.close(app) }.disabled(model.busy.contains(app.id + "-stop") || (model.observations[app.id]?.state == "stopped" && !model.busy.contains(app.id)))
        Toggle("登录后自动启动", isOn: Binding(get: { app.autoStart }, set: { model.setAuto(app, enabled: $0) }))
        Divider()
        Button("查看日志", systemImage: "text.alignleft") { model.logs(app) }
        Button("在访达中显示", systemImage: "folder") { model.reveal(app) }
        if let settings { Button("应用设置…", systemImage: "slider.horizontal.3", action: settings) }
        Button("移除应用…", systemImage: "minus.circle", role: .destructive) { model.remove(app) }
    }
}
struct LauncherView: View {
    @ObservedObject var model: AppModel
    @State private var settings = false
    @State private var selected: AppRecord?
    private let columns = [GridItem(.adaptive(minimum: 146, maximum: 185), spacing: 20)]
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.16), .cyan.opacity(0.08), .purple.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 24) {
                header
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(13).frame(maxWidth: 400).liquid(30)
                if !model.engineReady { engineNotice }
                if model.apps.isEmpty { emptyState }
                else if model.filtered.isEmpty { ContentUnavailableView.search(text: model.search).frame(maxHeight: .infinity) }
                else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 25) {
                            ForEach(model.filtered) { app in tile(app) }
                        }.padding(.horizontal, 8).padding(.vertical, 12)
                    }.scrollIndicators(.hidden)
                }
                footer
            }.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 18)
        }
        .frame(minWidth: 700, minHeight: 510)
        .sheet(isPresented: $settings) { SettingsView(model: model) }
        .sheet(item: $selected) { AppSettings(model: model, app: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .okdockerSettings)) { _ in settings = true }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("OkDocker").font(.system(size: 29, weight: .bold, design: .rounded))
                Text("你的服务，各在其位。 ").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 22, height: 22) }.buttonStyle(.plain).padding(10).liquid(24).help("设置")
            Button { model.importPanel() } label: { Label("添加应用", systemImage: "plus").fontWeight(.medium).padding(.horizontal, 8).padding(.vertical, 7) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).keyboardShortcut("o")
        }
    }
    private var engineNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) { Text("先让 Apple container 准备好").fontWeight(.semibold); Text("无需 Colima 或 Docker；每个容器运行于独立轻量 Linux VM。").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(model.busy.contains("engine") ? "启动中…" : "启动运行时") { model.startEngine() }.disabled(model.busy.contains("engine"))
        }.padding(16).liquid(20)
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 46, weight: .light)).foregroundStyle(.blue.gradient).padding(25).liquid(30)
            Text("给应用一个自己的空间").font(.system(size: 23, weight: .semibold, design: .rounded))
            Text("准备 okdocker.json → 导入文件夹 → 点击启动\n右键应用图标，即可打开、强制关闭和设置登录启动。").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack { Button("添加第一个应用") { model.importPanel() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule); RulesControls(model: model).buttonStyle(.bordered).buttonBorderShape(.capsule) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func tile(_ app: AppRecord) -> some View {
        let observation = model.observations[app.id] ?? .unknown
        return Button {
            if !model.busy.contains(app.id) && !model.busy.contains(app.id + "-stop") { observation.running > 0 ? model.open(app) : model.start(app) }
        } label: { VStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                AppArtwork(model: model, app: app)
                if model.busy.contains(app.id) { ProgressView().controlSize(.small).padding(6).background(.regularMaterial, in: Circle()).offset(x: 7, y: 4) }
            }
            Text(app.name).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing: 5) { StatusDot(observation: observation); Text(model.busy.contains(app.id) ? "操作中…" : (app.context == AppleRuntime.context ? observation.title : "旧 Docker · \(observation.title)")).font(.caption).foregroundStyle(.secondary); if app.autoStart { Image(systemName: "sunrise.fill").font(.caption2).foregroundStyle(.secondary) } }
        }
        .frame(maxWidth: .infinity).frame(height: 154).contentShape(RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
        .contextMenu { AppActions(model: model, app: app, settings: { selected = app }) }
        .help("\(observation.detail)\n点击启动 / 打开；右键查看更多选项")
        .accessibilityElement(children: .combine).accessibilityLabel("\(app.name)，\(observation.title)")
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(model.engineReady ? .green : .orange).frame(width: 6, height: 6)
            Text(model.engineText).lineLimit(1)
            Spacer()
            Text(model.message.isEmpty ? "\(model.apps.count) 个应用 · \(model.runningCount) 个运行中" : model.message).lineLimit(1).frame(maxWidth: 320, alignment: .trailing)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新真实状态").keyboardShortcut("r")
        }.font(.caption).foregroundStyle(.secondary)
    }
}
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var openWindow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("OkDocker").font(.system(.headline, design: .rounded)); Spacer(); Text("\(model.runningCount) 运行中").font(.caption).foregroundStyle(.secondary); Button(action: openWindow) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("打开启动器") }
            if model.apps.isEmpty { Text("还没有应用。打开启动器，导入应用文件夹即可。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12) }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.apps) { app in
                        let o = model.observations[app.id] ?? .unknown
                        HStack(spacing: 11) {
                            AppArtwork(model: model, app: app, size: 36)
                            VStack(alignment: .leading, spacing: 3) { Text(app.name).fontWeight(.medium); HStack(spacing: 5) { StatusDot(observation: o); Text(model.busy.contains(app.id) ? "操作中…" : o.title).font(.caption).foregroundStyle(.secondary) } }
                            Spacer()
                            if model.busy.contains(app.id) { ProgressView().controlSize(.small) }
                            else { Button { o.running > 0 ? model.open(app) : model.start(app) } label: { Image(systemName: o.running > 0 ? "safari" : "play.fill").frame(width: 24, height: 24) }.buttonStyle(.borderless).help(o.running > 0 ? "从浏览器打开" : "启动") }
                            Menu { AppActions(model: model, app: app) } label: { Image(systemName: "ellipsis").frame(width: 18) }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(9).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                        .contextMenu { AppActions(model: model, app: app) }
                    }
                }
            }.frame(maxHeight: model.apps.isEmpty ? 0 : min(CGFloat(model.apps.count) * 64, 370))
            Divider()
            HStack {
                Button("添加应用…", systemImage: "plus") { model.importPanel() }.buttonStyle(.plain)
                Spacer()
                Button("打开启动器", action: openWindow).buttonStyle(.plain)
            }.font(.subheadline)
            HStack { Text(model.engineReady ? "Apple container 已就绪" : "Apple container 未就绪").font(.caption).foregroundStyle(.secondary); Spacer(); Button("退出") { NSApp.terminate(nil) }.font(.caption).buttonStyle(.plain).help("退出管理器不会关闭已运行的容器") }
        }.padding(18).frame(width: 350)
    }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var context = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("设置").font(.system(size: 26, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 9) {
                Label("Apple container", systemImage: "shippingbox").font(.headline)
                Text("官方运行时 1.7.1 · macOS 26+ / Apple Silicon。每容器独立轻量 VM，不依赖 Docker context 或 Compose。旧 Docker 登记需确认停止后显式迁移。").font(.caption).foregroundStyle(.secondary)
                Text(model.engineText).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("启动 Apple 运行时") { model.startEngine() }.disabled(model.busy.contains("engine"))
                    if model.context != AppleRuntime.context { Button("设为默认后端") { model.chooseContext(AppleRuntime.context) } }
                    Button("官方下载") { NSWorkspace.shared.open(URL(string: "https://github.com/apple/container/releases/tag/1.7.1")!) }
                }
                Text("不要求逐应用分配套餐；官方 VM 默认容量仍存在（4 vCPU / 1 GiB），并非宿主预占。内存自动归还能力有限，不能保证无限弹性。").font(.caption).foregroundStyle(.secondary)
            }.padding(18).liquid(20)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("登录 Mac 时启动 OkDocker", isOn: Binding(get: { model.loginStatus == .enabled }, set: { model.registerLogin($0) }))
                Text("默认关闭。应用自己的自动启动也默认关闭，需在右键菜单单独开启。系统要求批准时会打开登录项设置。").font(.caption).foregroundStyle(.secondary)
                if model.loginStatus == .requiresApproval { Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() } }
            }.padding(18).liquid(20)
            Text("关闭窗口后保留菜单栏。退出 OkDocker 不会停止已运行的服务；右键“强制关闭应用”才会立即终止容器。安卓开关只控制 ADB 接入配置，不是恶意容器的设备隔离，也不代表所有 Mac 硬件直通。").font(.caption).foregroundStyle(.secondary)
            HStack { RulesControls(model: model); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 520).onAppear { context = model.context }
    }
}
struct AppSettings: View {
    @ObservedObject var model: AppModel
    let app: AppRecord
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: Manifest?
    @State private var loadError = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { AppArtwork(model: model, app: app, size: 50); Text(app.name).font(.title2.bold()); Spacer() }
            if let manifest {
                Text("授权目录").font(.headline); Text(app.root).textSelection(.enabled).font(.caption)
                LabeledContent("配置版本", value: manifest.version ?? "未设置（兼容旧配置）")
                LabeledContent("前端", value: manifest.frontend.url.absoluteString)
                LabeledContent("服务端", value: manifest.backend.url.absoluteString)
                Toggle("允许局域网访问", isOn: Binding(get: { model.apps.first(where: { $0.id == app.id })?.lanAccess == true }, set: { model.setLAN(app, enabled: $0) })).disabled(model.busy.contains("lan-" + app.id))
                if let status = model.lanStatuses[app.id], status.enabled {
                    if !status.error.isEmpty { Text(status.error).font(.caption).foregroundStyle(.orange) }
                    ForEach(status.addresses, id: \.self) { host in
                        if let url = LANAccess.url(manifest.frontend, host: host) {
                            HStack { Link(url.absoluteString, destination: url).textSelection(.enabled); Spacer(); Button { model.copyText(url.absoluteString, message: "已复制局域网前端地址") } label: { Image(systemName: "doc.on.doc") }.help("复制局域网地址") }.font(.caption)
                        }
                    }
                    Text("同网段设备可访问前后端，认证由应用提供；地址随 Mac 网络变化。不会重建容器或开放 ADB 端口。").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("安卓设备", value: manifest.hostAndroidDevices == true ? "全部已授权设备（共享 ADB）" : "不注入 ADB 通道")
                LabeledContent("运行时", value: app.context)
                if app.context != AppleRuntime.context { Button("迁移登记到 Apple container…") { model.migrate(app) } }
                Toggle("登录后自动启动服务", isOn: Binding(get: { model.apps.first(where: { $0.id == app.id })?.autoStart ?? false }, set: { model.setAuto(app, enabled: $0) }))
                Text("修改源码后提高 okdocker.json 的 version，再启动或检查版本更新：重新构建并切换部署，旧容器停止并保留。其他配置变化须先关闭并重新导入确认。更新会短暂停机，持久数据应显式挂载并自行备份。ADB 开关不是网络防火墙；强制关闭可能中断写入。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if loadError.isEmpty { ProgressView("读取配置…请正常批准系统目录访问请求") }
            else { Text(loadError).foregroundStyle(.orange) }
            HStack { Button("打开目录") { model.reveal(app) }; RulesControls(model: model); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 510).background(Color(nsColor: .windowBackgroundColor))
        .task {
            let app = app
            let result = await Task.detached(priority: .utility) { Result { try Runtime.approved(app).manifest } }.value
            switch result { case .success(let value): manifest = value; case .failure(let error): loadError = error.localizedDescription }
        }
    }
}
extension Notification.Name { static let okdockerSettings = Notification.Name("dev.okdocker.settings") }
enum ConfigurationRules {
    static func text(resources: URL = Runtime.resources) throws -> String {
        let file = resources.appendingPathComponent("CONFIGURATION.md")
        let rules = try String(contentsOf: file, encoding: .utf8)
        return "请根据以下 OkDocker 规则，检查我提供的项目并帮助生成或调整 okdocker.json、必要的 Dockerfile 和 Linux 构建脚本。先确认真实目录、启动命令和端口；不要猜测，不要输出密钥；只修改我授权的项目目录。局域网访问由用户在 OkDocker 中单独开启，不能通过配置文件自动授权。\n\n" + rules
    }
    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw Problem("无法写入剪贴板") }
    }
}
struct RulesControls: View {
    @ObservedObject var model: AppModel
    @State private var presented = false
    var body: some View {
        HStack {
            Button("配置规则") { presented = true }
            Button("复制给 AI", systemImage: "doc.on.doc") { model.copyRules() }.help("复制完整配置规则，不包含已导入应用的数据或凭据")
        }.sheet(isPresented: $presented) { RulesView(model: model) }
    }
}
struct RulesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("应用配置规则").font(.title2.bold()); Spacer(); Button("复制完整规则给 AI", systemImage: "doc.on.doc") { model.copyText(text, message: "已复制完整配置规则，可粘贴给 AI") }.buttonStyle(.borderedProminent).disabled(text.isEmpty) }
            Text("把规则粘贴给 AI，再描述你的项目目录和需求，让 AI 帮你准备导入配置。这里不包含已导入应用的文件或凭据。").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(error.isEmpty ? text : error).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }.background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            HStack { Button("打开 Markdown 文档") { NSWorkspace.shared.open(Runtime.resources.appendingPathComponent("CONFIGURATION.md")) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 750, height: 610).background(Color(nsColor: .windowBackgroundColor))
        .task {
            let result = await Task.detached(priority: .utility) { Result { try ConfigurationRules.text() } }.value
            switch result { case .success(let value): text = value; case .failure(let value): error = value.localizedDescription }
        }
    }
}
