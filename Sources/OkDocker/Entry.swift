import AppKit
import SwiftUI
import ServiceManagement
import Darwin

@main struct Entry {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--adb-bridge", arguments.count == 2 {
            Task { do { try await AndroidBridge.run(config: URL(fileURLWithPath: arguments[1])) } catch { exit(1) } }
            dispatchMain()
        }
        if arguments.first == "--lan-gateway", arguments.count == 2 {
            Task { do { try await LANAccess.run(config: URL(fileURLWithPath: arguments[1])); exit(0) } catch { exit(1) } }
            dispatchMain()
        }
        if arguments.first == "--cli" {
            do { try Runtime.upgradeBackendDefault(); try cli(Array(arguments.dropFirst())); exit(0) }
            catch { fputs("OkDocker: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    static func printJSON<T: Encodable>(_ object: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(object), as: UTF8.self))
    }
    @MainActor static func cli(_ args: [String]) throws {
        guard let action = args.first else { throw Problem(tr("用法：--cli validate/import/list/start/close/status/deployments/lan/rules/autostart/forget/context/engine")) }
        let operand = args.count > 1 ? args[1] : ""
        switch action {
        case "validate":
            let v = try validate(root: URL(fileURLWithPath: operand)); print(L("Valid: \(v.manifest.name); frontend \(v.manifest.frontend.url); backend \(v.manifest.backend.url); Android \(v.manifest.hostAndroidDevices == true ? "on" : "off")", "有效：\(v.manifest.name)；前端 \(v.manifest.frontend.url)；服务端 \(v.manifest.backend.url)；安卓 \(v.manifest.hostAndroidDevices == true ? "开放" : "关闭")"))
        case "context": try Runtime.localContext(operand); try Runtime.transaction { $0.context = operand }; print(L("Selected \(operand)", "已选择 \(operand)"))
        case "engine": print(try Runtime.engine(operand.isEmpty ? Runtime.load().context : operand))
        case "engine-start": print(try AppleRuntime.startEngine())
        case "migrate": print(try Runtime.migrateToApple(Runtime.record(operand), confirmOldStopped: args.contains("--confirm-old-stopped")))
        case "login-status": print(String(describing: SMAppService.mainApp.status))
        case "login":
            guard ["on", "off"].contains(operand) else { throw Problem("login on|off") }
            let service = SMAppService.mainApp
            if operand == "on" {
                if service.status != .enabled { try service.register() }
            } else {
                if [.enabled, .requiresApproval].contains(service.status) { try service.unregister() }
                for app in try Runtime.load().apps where app.autoStart { try Runtime.autostart(app, enabled: false) }
            }
            print(String(describing: service.status))
        case "login-self-test":
            let service = SMAppService.mainApp
            guard ![SMAppService.Status.enabled, .requiresApproval].contains(service.status) else { throw Problem(tr("登录项已有设置，不自动改动；请手动验证")) }
            defer { try? service.unregister() }
            try service.register()
            let registered = service.status
            try service.unregister()
            struct LoginTest: Encodable { var registeredStatus: String; var afterUnregister: String; var enabled: Bool }
            try printJSON(LoginTest(registeredStatus: String(describing: registered), afterUnregister: String(describing: service.status), enabled: registered == .enabled))
        case "import":
            let defaultContext = try Runtime.load().context
            let context = args.firstIndex(of: "--context").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? defaultContext
            try printJSON(Runtime.importApp(URL(fileURLWithPath: operand), context: context))
        case "list": try printJSON(Runtime.load().apps)
        case "start": print(try Runtime.start(Runtime.record(operand)))
        case "close":
            guard args.contains("--force") else { throw Problem(tr("关闭会发送 SIGKILL，需显式加 --force；不删除数据")) }
            print(try Runtime.forceStop(Runtime.record(operand)))
        case "status": try printJSON(Runtime.observe(Runtime.record(operand)))
        case "deployments":
            let record = try Runtime.record(operand)
            guard record.context == AppleRuntime.context else { throw Problem(tr("部署历史仅支持 Apple container 后端")) }
            try printJSON(AppleRuntime.deployments(record))
        case "lan":
            guard args.count == 3, ["on", "off", "status"].contains(args[2]) else { throw Problem("lan ID on|off|status") }
            let record = try Runtime.record(operand)
            if args[2] == "status" { try printJSON(LANAccess.status(record)) }
            else { print(try LANAccess.set(record, enabled: args[2] == "on")) }
        case "rules": print(try ConfigurationRules.text())
        case "autostart":
            guard args.count == 3, ["on", "off"].contains(args[2]) else { throw Problem("autostart ID on|off") }
            let enabled = args[2] == "on"
            if enabled {
                if ![SMAppService.Status.enabled, .requiresApproval].contains(SMAppService.mainApp.status) { try SMAppService.mainApp.register() }
                guard SMAppService.mainApp.status == .enabled else { throw Problem(tr("需要用户在系统登录项设置中批准 OkDocker，未开启应用自动启动")) }
            }
            try Runtime.autostart(Runtime.record(operand), enabled: enabled); print(enabled ? tr("已开启登录启动") : tr("已关闭登录启动"))
        case "forget": try Runtime.remove(Runtime.record(operand)); print(tr("已移除登记，目录和数据保留"))
        default: throw Problem(L("Unknown command: \(action)", "未知命令：\(action)"))
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    var item: NSStatusItem!
    var popover: NSPopover!
    var menuLanguage = LanguageSettings.code
    private var lockFD: Int32 = -1
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try Runtime.prepare() } catch { NSApp.terminate(nil); return }
        lockFD = Darwin.open(Runtime.support.appendingPathComponent("ui.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.okdocker.show"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        do { try Runtime.upgradeBackendDefault() } catch {
            let alert = NSAlert(); alert.messageText = tr("注册表迁移未完成"); alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        model = AppModel()
        setupMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "OkDocker"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 700, height: 510)
        window.setFrameAutosaveName("OkDockerLauncher"); window.delegate = self
        window.backgroundColor = .clear; window.isOpaque = false
        let visual = NSVisualEffectView(); visual.material = .underWindowBackground; visual.blendingMode = .behindWindow; visual.state = .active
        let host = NSHostingView(rootView: LauncherView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(host); NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: visual.leadingAnchor), host.trailingAnchor.constraint(equalTo: visual.trailingAnchor), host.topAnchor.constraint(equalTo: visual.topAnchor), host.bottomAnchor.constraint(equalTo: visual.bottomAnchor)])
        window.contentView = visual
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "OkDocker")
            image?.isTemplate = true; button.image = image; button.target = self; button.action = #selector(togglePopover)
            button.toolTip = tr("OkDocker · Apple container 应用启动器")
        }
        popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model, openWindow: { [weak self] in self?.showLauncher() }))
        model.changed = { [weak self] in
            guard let self else { return }
            if self.menuLanguage != LanguageSettings.code {
                self.menuLanguage = LanguageSettings.code
                self.setupMenu()
            }
            self.item.button?.toolTip = L("OkDocker · \(self.model.runningCount) apps running", "OkDocker · \(self.model.runningCount) 个应用运行中")
        }
        model.showWindow = { [weak self] in self?.showLauncher() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showFromNotification), name: Notification.Name("dev.okdocker.show"), object: nil)
        if !CommandLine.arguments.contains("--background") { window.center(); showLauncher() }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for _ in 0..<180 {
                    let pending = self.model.apps.contains { $0.autoStart && self.model.observations[$0.id]?.healthy != true }
                    if !self.model.refreshing && self.model.busy.isEmpty && !pending { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if CommandLine.arguments.contains("--ui-feature-smoke") { await self.smokeFeatureViews(directory) }
                self.smokeTest(directory)
            }
        }
    }
    private func smokeFeatureViews(_ directory: URL) async {
        var views: [(String, AnyView)] = [("rules", AnyView(RulesView(model: model)))]
        if let app = model.apps.first {
            views.append(("app-settings", AnyView(AppSettings(model: model, app: app))))
            views.append(("startup-logs", AnyView(AppLogs(app: app))))
        }
        var captured: [String] = []
        for (name, content) in views {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: name == "rules" ? 810 : name == "startup-logs" ? 900 : 570, height: 670), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.title = "OkDocker · \(name)"
            let host = NSHostingView(rootView: content); panel.contentView = host; panel.center(); panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            host.layoutSubtreeIfNeeded()
            if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]), (try? Runtime.write(data, to: directory.appendingPathComponent(name + ".png"))) != nil { captured.append(name) }
            }
            panel.close()
        }
        try? Runtime.json(["captured": captured, "onlyOwnViews": true], to: directory.appendingPathComponent("feature-views.json"))
    }
    private func smokeTest(_ directory: URL) {
        // Capture only this application's own view, never the user's desktop.
        var result: [String: Any] = ["windowVisible": window.isVisible, "menuBarPresent": item.button != nil, "loginItemStatus": String(describing: SMAppService.mainApp.status)]
        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                do { try Runtime.write(png, to: directory.appendingPathComponent("launcher.png")); result["ownWindowCaptured"] = true }
                catch { result["ownWindowCaptured"] = false }
            }
        }
        window.performClose(nil)
        result["closeKeepsMenuBar"] = !window.isVisible && item.button != nil
        showLauncher(); result["reopenWorks"] = window.isVisible
        result["menuTitles"] = NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []
        try? Runtime.json(result, to: directory.appendingPathComponent("native-ui.json"))
        NSApp.terminate(nil)
    }
    func setupMenu() {
        let menu = NSMenu()
        let appRoot = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("关于 OkDocker"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        let show = appMenu.addItem(withTitle: tr("打开启动器"), action: #selector(showFromNotification), keyEquivalent: "1"); show.target = self
        let importItem = appMenu.addItem(withTitle: tr("添加应用…"), action: #selector(importApp), keyEquivalent: "o"); importItem.target = self
        let settings = appMenu.addItem(withTitle: tr("设置…"), action: #selector(settings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("隐藏 OkDocker"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("退出 OkDocker"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appRoot.submenu = appMenu; menu.addItem(appRoot)
        let editRoot = NSMenuItem(); let edit = NSMenu(title: tr("编辑"))
        for (title, action, key) in [(tr("撤销"), "undo:", "z"), (tr("剪切"), "cut:", "x"), (tr("拷贝"), "copy:", "c"), (tr("粘贴"), "paste:", "v"), (tr("全选"), "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        editRoot.submenu = edit; menu.addItem(editRoot); NSApp.mainMenu = menu
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func showFromNotification() { showLauncher() }
    @objc func importApp() { showLauncher(); model.importPanel() }
    @objc func settings() { showLauncher(); NotificationCenter.default.post(name: .okdockerSettings, object: nil) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "OkDocker", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? tr("开发版"), .credits: NSAttributedString(string: L("Native Apple container app launcher\nOnly the application directory is exposed by default. Android access is an explicit grant.\nForce stop interrupts work and writes.", "Apple container 原生应用启动器\n默认仅开放应用目录 · 安卓接入显式授权\n强制关闭会中断任务与写入。"))]) }
    func showLauncher() { popover?.performClose(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showLauncher(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
}
