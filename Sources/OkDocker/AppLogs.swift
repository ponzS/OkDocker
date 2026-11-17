import AppKit
import SwiftUI

struct AppLogs: View {
    let app: AppRecord
    @State private var tab = 0
    @State private var text = ""
    @State private var follow = true
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker(L("Log", "日志"), selection: $tab) {
                    Text(L("Startup / build", "启动 / 构建")).tag(0)
                    Text(L("Container", "容器运行")).tag(1)
                }.pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Toggle(L("Follow output", "跟随输出"), isOn: $follow)
                Button(L("Open file", "打开文件")) { NSWorkspace.shared.open(file) }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty ? L("Waiting for log output…", "等待日志输出…") : text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 1).id("end")
                    }.padding(12)
                }.background(.background).border(.secondary.opacity(0.2))
                    .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Text(L("Refreshes every second. Showing the last 256 KiB. Logs may contain application secrets.", "每秒刷新，显示最近 256 KiB；日志可能包含应用自己的敏感内容。")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 740, minHeight: 470).background(Color(nsColor: .windowBackgroundColor))
            .task(id: tab) {
                while !Task.isCancelled {
                    let url = file
                    text = await Task.detached(priority: .utility) { Startup.tail(url) }.value
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
    private var file: URL { tab == 0 ? Startup.log(app) : Runtime.appDirectory(app).appendingPathComponent("container.log") }
}
