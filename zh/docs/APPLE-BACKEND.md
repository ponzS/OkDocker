[English](../../docs/APPLE-BACKEND.md)

# Apple container 后端 · 0.3

状态：0.2 本机验证版；验收结果单独记录，不能沿用 0.1 Docker 的通过结论。

## 决策与职责

按用户 2026-11-16 授权，默认运行时改为 Apple `container`，不再要求 Colima / Docker / Compose。继续使用原生 SwiftUI/AppKit；不重写官方 vminitd、VM 管理或镜像构建器。首版接入官方 CLI，而不是把整个官方运行时打包进应用。Apple container 仍通过 Containerization / Virtualization.framework 为每个容器启动独立 Linux VM。

新增 `Sources/OkDocker/AppleRuntime.swift`：仅负责官方 CLI 协议、带所有权标签的容器/网络、构建、检查和启动。原 `Runtime.swift` 继续承担注册表、目录审批、启动/关闭互斥、取消与端口保护，并分发到对应后端；已有 Compose 代码仅作为旧登记的兼容和清理路径。不能用 Docker context 冒充 Apple 后端。

- 官方运行时固定验收 `1.7.1`，tag commit `a15b46097aa4c2325da13c1fb5192b9274aab083`；Apache-2.0。
- 安装包：<https://github.com/apple/container/releases/download/1.7.1/container-1.7.1-installer-signed.pkg>
- SHA256：`b6739caf3d47ca53a78f1a7edf32521420a75c7941838c3cefa75f30b80f5a97`。
- 已通过 `pkgutil --check-signature`：Apple Inc. - Containerization (`UPBK2H6LZM`)，Apple 公证可信。正常系统安装器请求管理员批准，不去掉隔离属性或绕过系统授权。
- 官方内核：Kata 4.3.1 ARM64，归档 SHA256 `2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6`。首次官方 URLSession 下载遇到 TLS 关闭；正常 TLS curl 重试并核对官方摘要后才本地安装，未跳过任何校验。
- 最低 macOS 26 / Apple Silicon；镜像限定 Linux arm64，不默默启用 Rosetta。

## 接口与迁移

内部后端键为 `apple-container`；保留旧记录的 context，避免悄悄改变运行实例。注册表升级先备份，默认后端转为 Apple；旧应用的登录自动启动暂停。旧卡片明确标为待迁移，迁移只修改登记、保持自动启动关闭，不构建或启动服务，不搬运或删除数据。

迁移需要显式确认旧 Docker 实例已停止；若旧引擎可连接，还会核查实际 running=0。旧引擎不可连接不能自动断言旧容器已停止。迁移仅限管理器登记，不切换已有宿主部署或接管其数据；切换前须确认原服务已关闭。

新的受控声明仍使用 schemaVersion 1，不接收额外 CLI 参数、任意 Compose、宿主命令、socket/USB 全设备映射或 SSH-agent/home 隐式共享。容器端口固定 127.0.0.1；0.2.1 增加用户单独授权的宿主 LAN 助手，不改容器配置、不重建可写层（详见 CONFIGURATION.md）。启动前及构建后检查真实 LISTEN，创建后审计官方 inspect 的实际挂载、网络、标签、端口。普通配置变更仍须在停止后重新导入审批；0.3 允许仅应用 `version` 变化时复用依赖缓存重建与切换。新镜像/停止态容器准备并审计通过后才停旧服务，原子选择新代际再启动；旧容器可写层和镜像保留，不静默删除。构建脚本通过 `build.script` 在 Dockerfile 的 Linux 阶段执行，不成为宿主命令钩子。完整版本/持久化语义见 CONFIGURATION.md 与 ARCHITECTURE.md。

每应用独立 vmnet 网络。官方自定义网络不提供 Compose 式裸服务名发现；不宣称任意多服务 Compose 等价。ADB 不依赖自定义网络 DNS 或动态 IP。已放弃不可绑定的 vmnet 网关监听方案。新建部署把 Mac 私有令牌 socket 挂进获准后端容器，由同容器里的转发程序注入令牌并在本地 Unix socket 上提供给应用。没有 TCP 桥监听，不修改 PF / DNS / Private Relay。socket 路径位于当前用户临时目录下的 0700 应用子目录，避免 sockaddr_un 长度限制；只给已授权后端注入固定 socket，清理不涉及共享 ADB。

已创建的旧 sidecar 不就地改写；版本切换成功后停止该虚拟机。令牌目录只读。关闭、重新启动可保留后端可写层且不受 VM IP 变化影响。ADB 开关仍不宣称已通过恶意程序强制隔离。

不强制逐应用填写 CPU/内存套餐，也不承诺无限弹性：官方 CLI 的 VM 启动容量及默认上限仍存在（1.7.1 默认 4 vCPU / 1 GiB），这不是固定宿主预占；guest 释放内存未必能归还 Mac。保留原始测量，不宣称一定比 Colima 更省资源。

## 生命周期与验收门槛

- 从真实 `container list --all --format json` 读取状态；HTTP 与挂载 I/O 分别确认。
- 容器按应用 ID + 支持目录摘要标签归属，网络同样校验标签；不用 `--all` 删除/停止资源。观察/日志限定当前选中部署，关闭/移除覆盖该应用所有代际；应用版本与部署标识均写入标签。
- 强制关闭发送 KILL；等待所有创建/启动客户端取消后再次核查，不删除容器可写层或宿主数据，不停共享运行时/ADB。
- UI 退出不关闭服务；重开按实际状态恢复。登录项默认关闭。
- 验收独立示例：导入/真实 Linux arm64/挂载与端口、SIGKILL、宿主与容器可写层持久化、两应用互不影响、旧记录显式迁移、配置变更、恶意环境/参数、占用端口、启动取消/孤儿客户端、真实 GUI 冷启动与文件/HTTP I/O。

最终通过范围与未通过项在 `VALIDATION.md` 单独记录。旧 Docker 报告是历史证据，不算 Apple 后端验收。
