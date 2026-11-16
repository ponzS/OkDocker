# 架构与边界 · 0.2

默认链路是 **OkDocker → Apple container 1.7.1 CLI → 官方 Containerization / Virtualization.framework**。每容器独立 Linux VM；不是 Colima 中运行 Docker，也没有将 Linux 容器伪装成 macOS 原生进程。官方运行时单独签名安装，不内嵌未签名服务，不重写 vminitd。

## 模块职责

- `Models.swift`：schemaVersion 1、目录审批/路径约束与配置摘要。未知权限、越界、特殊文件、非法端口/URL 均拒绝。
- `Runtime.swift`：唯一注册表、原子写入、默认后端升级/备份、显式迁移、启动/关闭锁、取消标记及实际端口占用保护。按登记的后端分发。旧 Compose 代码只保留兼容关闭/观察/清理和 CLI 显式使用，不作为默认路径。
- `AppleRuntime.swift`：新增的官方 CLI 适配。负责参数数组、OCI 构建/镜像、带标签的容器与网络、inspect 审计、实际状态和 KILL。现有 Docker/Compose 接线无法承接 Apple 的 XPC/CLI 与每容器 VM 语义，所以分离此适配，不复制注册表和策略锁。
- `AppModel.swift`：异步编排、采样、独立 HTTP 就绪探针、SMAppService。旧卡片显式迁移，不能因换默认后端悄悄启动另一份部署。
- `Views.swift` / `Entry.swift`：SwiftUI/AppKit 启动器、菜单栏、导入审批、设置及 CLI。主线程不执行镜像构建或 Docker/Apple CLI。
- `LANAccess.swift`：用户独立授权的宿主 TCP 入口与进程身份检查；只转发指定应用的已审批前后端 loopback 端口到当前私有 Wi-Fi/以太网 IPv4。独立助手在 UI 退出后保留，开关/关闭仅影响自己的入口。直接改 Apple 发布参数需替换现有容器并丢失未挂载可写层，所以不能由原部署适配承担；不为此修改配置摘要或重建 VM。
- `AndroidBridge.swift`：每应用独立令牌助手。Apple 路径只监听当前用户私有临时目录的 Unix socket；legacy Docker 保留 loopback TCP 模式。共享 Mac ADB 仍只在原 `127.0.0.1:5037`，不转移 USB/ADB 凭据。
- `Resources/Android`：私有 Python sidecar，复用官方 `.into` socket 挂载和 `.outOf` 发布；固定的另一条 Unix socket 接入获准后端。后端地址 `localfilesystem:/run/okdocker-adb.sock` 不随 VM IP 改变。不开放手机桥 TCP，也不改 PF/DNS/Private Relay。
- `integrations/`：其他应用的部署模板和只含允许源码的构建暂存；业务源码与真实数据不迁入管理器。
- `scripts/install-app.py`：显式本机升级、旧包备份与原子替换；与只构建 dist 的脚本分开，避免每次打包悄悄替换运行中的应用。既不修改登录设置，也不启停运行时/容器或清除系统隔离属性。

## 生命周期与持久化

关闭窗口保留菜单栏；退出 UI 保留服务。重开从 `container list --all --format json` 恢复实际状态，再检查 HTTP。Running 不是目录/网页/ADB 都健康的证明。

每应用使用唯一项目名及应用 ID + support 路径摘要标签；网络同样校验所有权。停止/删除不使用 `--all`。强制关闭发送 KILL，撤销该项目启动/构建客户端，等待启动锁，再核查实际 running=0；不停止共享引擎、构建器或 ADB。官方 `container build` 会 exec 为 build 插件，孤儿取消必须匹配该插件路径及项目/支持目录标签，不能只找 `container build` 进程名。

停止/启动复用原容器，保留可写层和宿主挂载。配置摘要不同拒绝静默重建；备份后明确移除再导入。移除保留宿主目录，但会丢失容器未挂载可写层。源码重建也是显式的新部署流程，不承诺热更新。

局域网许可保存在 `AppRecord.lanAccess`（可选字段，缺失即关闭），不接受来自导入 manifest 的自动授权。新增 `--cli lan ID on|off|status`；新连接核查原发布者 PID、启动时间、命令与 loopback LISTEN，拒绝复用其他服务的端口。私有地址变动重新绑定并断开旧连接；不保证公网转发设备或其他代理的安全性，认证由应用实现。关闭入口不改容器，停止容器先关闭入口，防止迟到转发。

## 信任与边界

CLI 不经 shell，不继承 `CONTAINER_*` / Docker 端点覆盖，不读取应用 `.env`。只传明确目录、平台、网络、端口、命令与完整 `KEY=value`；源目录/目标含 CLI 分隔字符则拒绝。创建完成、启动之前审计实际配置，不把命令成功当成已授权。

应用不能提交 privileged、外部网络/卷、host PID/network、socket/设备、SSH/home 共享或自定义内核/运行时。Apple 接线不支持的单文件绑定不会偷偷扩大为对父目录的授权。ADB 的两个固定私有 socket 与只读配置目录仅在显式授权后注入。sidecar drop ALL capabilities；为发布 Unix socket 使用隔离 VM 的可写根，而不是 workload 私有 tmpfs（官方 outOf 转发无法看到该命名空间）。宿主只读配置不因此改成可写。

同 UID 的恶意宿主程序、宿主管理员和有权控制官方运行时的人不在防御范围；并发路径替换也不是已完成强沙箱。每应用独立 vmnet 不等于完整出站防火墙。安卓仍只支持可信代码，不用历史 Colima 旁路结果冒充 Apple 网络验证。

不强制用户填写资源配额，但官方 VM 默认容量及构建器资源仍存在。没有重写弹性资源管理，也不承诺活跃 guest 释放内存必定归还 Mac。详见 [迁移决策](APPLE-BACKEND.md) 与 [分后端验证记录](VALIDATION.md)。
