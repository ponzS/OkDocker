# 本机验证记录 · 0.2.1 Apple container 验证版

## 0.2.1 局域网与规则复制（2026-11-16）

- 通用管理器 UI / CONFIGURATION 不再包含特定业务名称、发帖确认等提示；保留通用的数据写入、认证、权限与生命周期说明。
- **51 项 Swift 测试通过**：原 40 + LAN 私有地址/物理接口筛选、旧登记缺省关闭、许可编码、manifest 不得自动授权、URL、完整通用 AI 规则，以及用独立私有 NSPasteboard 验证逐字复制（不覆盖用户剪贴板）。`artifacts/lan-swift-test.log`。
- **26 项真实 LAN 检查通过**：两个隔离应用、默认不开放、明确开关、实际监听 Mac 地址、独立前后端端口、本机入口不变、inspect 配置和 guest boot ID 不变、其他应用不被公开、完整 1 MiB 上传/下载、HTTP Upgrade 双向数据、运行中移除被拒绝且不干扰入口、断开既有连接、丢失就绪文件也能撤销助手、退出 GUI 保留入口、强制关闭与重启、配置变化仍可撤销，以及原端口被其他本地服务复用后不会误转发。`artifacts/lan-validation/report.json`。
- **原生界面**：实际配置规则窗口与 LAN 设置窗口已加载、仅捕获自身视图；规则带完整复制给 AI 按钮和说明，设置显示实际已监听的 Mac 地址与复制按钮。测试图在报告 work/ui 下。没有采集用户桌面或手机屏幕。
- **核心 30 项 / 取消 7 项回归通过**：`artifacts/lan-core-regression.log`、`artifacts/lan-cancellation-regression.log`。

### 未通过边界：物理手机网络

本机请求实际 Mac LAN 地址已通过，但此轮 **6 台已授权手机的 LAN HTTP 未成功**，不能声称手机端验收通过。Mac 观测到 `192.168.10.124`、`192.168.31.159`，手机大多在 31 网段、另有蜂窝路径。独立于 OkDocker 的临时 Python HTTP listener（只返回固定测试文本，测试后移除）也收到手机 `nc: connect: No route to host`，说明基础手机→Mac 路径同样未建立；未单独确定是无线终端隔离、路由或其他网络限制。

只读取了系统防火墙状态（当时 disabled），**没有关闭/修改防火墙、TCC、路由、手机 Wi-Fi 或系统授权**。需在真实客户端可达的网络上继续验收；不能把 Mac 本机回环到 LAN IP 的成功冒充物理 LAN 客户端成功。没有访问用户应用的业务 API、重建其 VM 或修改其文件。

### 实现排障记录

Network.framework `NWListener` 在与官方 loopback 发布者共用端口时返回 EADDRINUSE；同地址/端口的 POSIX 特定地址 bind/listen 验证可用，因此 LAN 独立助手使用 POSIX socket + 有界 poll 双向转发，不改官方容器发布参数。每助手最多 64 条连接、每方向最多 64 KiB 缓冲；没有对吞吐、延迟或更省内存作性能结论。仅私有 en* IPv4，IPv6/VPN/公网不在支持范围。

复验：`swift test`、`bash scripts/build-app.sh`、`python3 tests/lan_integration.py`。若真实手机不在可达网络，报告保留 `realPhoneLANReadOnlyHTTP: false`，不伪造通过。

---

## 0.2 本轮结论（2026-11-16）

默认接线已改为 Apple 官方 **container 1.7.1**，不是 Colima/Docker context 别名。macOS 27.2 / Apple M4 / arm64 / 16 GiB，本机原生 UI 与官方运行时。以下结论来自独立目录、真实 Linux VM、文件、HTTP 与只读手机操作，不是模拟值。仍是本机验证版，不代表全硬件、所有网络权限或真实发布验收。

### 已通过范围

- **Swift 40 项**：原 17 项配置/路径/端口保护 + Apple 参数、所有权、未知状态 fail-closed、实际挂载/网络/端口/socket/平台/运行时/能力审计。`artifacts/apple-swift-test.log`。
- **Apple 核心 30 项**：两个真实应用、arm64、仅授权挂载、loopback 端口、字面环境与恶意 `.env`、关闭安卓不注入通道、私有网络、忽略 TERM 后 KILL、另一应用存活、宿主与容器可写层重启保留、配置变化拒绝静默删层、wildcard 端口占用前置阻断、旧注册表备份与显式登记迁移。`artifacts/apple-validation/report.json`。
- **取消 7 项**：真实待处理构建、正常启动器与被杀父进程后的孤儿 build 插件客户端按项目与支持目录摘要撤销；等待 48 秒未晚到启动应用，不停止共享构建器。官方 CLI 会 exec 到 build 插件，已修复只匹配原 CLI 名称会漏掉孤儿的问题。`artifacts/apple-cancellation/report.json`。
- **ADB 11 项**：官方 Unix socket `.into` / `.outOf` 链、私有目录/0600 socket、错误令牌拒绝、拒绝共享 ADB shutdown、实际设备枚举与只读 getprop、关闭不动共享服务、重启不删后端可写层且通道恢复。此轮 **2 台已授权在线手机**，不沿用历史 7 台数量。`artifacts/apple-android/report.json`。
- **流水线 16 项**：仅 allowlist 源码构建、新 SQLite、无 Key/任务/素材；真实 Linux arm64、网页/health、FFmpeg、设置写入/SIGKILL 后持久化、重启仍暂停、实际 Linux ADB 经稳定 Unix 通道列出手机和只读 getprop。没有 AI/发帖/安装/输入操作。`artifacts/apple-xhs/report.json`。
- **原生 UI 与真正冷运行时**：正常 SMAppService 注册/注销恢复原关闭偏好；在共享运行时没有其他工作时先正常停止服务，由 GUI 启动官方运行时、自动启动独立 fixture、读取实际挂载网页内容；主窗口/菜单栏、关闭重开、仅捕获自身视图、UI 退出后网页仍可访问，测试资源最后关闭移除。没有实际注销 Mac 账号。`artifacts/apple-ui/report.json`。

### 明确限制与排障记录

1. 官方运行时首次内核下载 TLS 中断；改为正常 TLS 下载同一官方归档，并同时以官方 SHA256 和 `container system kernel set --digest` 校验，没有关闭签名/TLS/摘要。签名安装包 Apple 公证可信；这不等于 OkDocker 本身已做 Developer ID 分发公证。
2. 首次流水线测试中，Mac 直连 VM 的 HTTP 正常，官方端口 helper 返回 `No route to host`。打开系统本地网络设置提示正常授权后复验通过；未单独确定是权限还是瞬态网络，**没有自动授权、改 TCC/PF 或改成直接 VM IP 冒充 loopback 通过**。用户遇到同样情况应检查系统本地网络权限并按配置排查。运行中/进程存在不是 HTTP 就绪。
3. vmnet 网关不是可直接绑定的 Mac 接口，未采用对 LAN 开放监听的变通。ADB 改用官方 Unix socket。helper 在独立 VM 可写根创建发布 socket，因为 workload tmpfs 中的 socket 对官方 outOf relay 不可见；宿主配置保持只读，capabilities 全部移除。
4. Android 开关不承诺恶意出站强隔离；官方自定义网络没有 Compose 式裸服务名发现；单文件挂载不会自动扩大为父目录授权。镜像源码变更需明确备份/重建，不做静默删层或源码热更新。
5. 官方每 VM 默认 4 vCPU/1 GiB，构建器默认 2 vCPU/2 GiB；不是固定宿主预占，也不等于无限弹性。没有完成多负载内存回收性能验收，不承诺一定比 Colima 更省内存。官方构建器自己的 privileged guest/Rosetta 支持是上游实现；产品工作负载明确 arm64、不开 Rosetta，不给应用自定义这些权限。

### 生产保护

本任务未发送宿主服务停止/重启指令，原 ADB listener 5617 未变化；Key 仍可用。**最终复核发现宿主进程已从早期 67077 变为 89789（20:28:06 启动），变化原因未确认，不能声称整个期间 PID 不变。** 完整隔离流水线测试记录的是其测试前后 PID 相同，业务引擎均为 **paused / running=false**；没有擅自恢复成历史记录里的 running=true，也没有发送 start-publishing。生产目录从未挂到 Apple 测试 VM。默认登记迁移只修改注册表并保留备份、关闭自动启动，真正生产切换仍须另行收尾/备份/正常停宿主。

### 0.2 复验

```sh
bash scripts/build-app.sh
swift test
OKDOCKER_BIN="$PWD/dist/OkDocker.app/Contents/MacOS/OkDocker" python3 tests/apple_integration.py
python3 tests/apple_cancellation.py
python3 tests/apple_android.py
python3 tests/apple_xhs_integration.py
# GUI 冷启动测试必须先确认没有其他 Apple 容器/构建任务；脚本会拒绝停止其他工作
python3 tests/apple_ui_smoke.py
```

测试源码与报告在项目内；运行期 fixture 在本应用 Application Support 的 `Validation/Apple*/`。原生生产不属于测试 fixture。历史 Docker 脚本/报告保留仅供回归参考，不作为 Apple 结果。

---

# 历史：0.1 Docker/Colima 验证版（不是当前默认后端）

## 结论与未通过项

**原生应用与预先就绪的 Docker 运行时可走通导入、启动、网页、真实状态、SIGKILL、数据保留和共享 ADB。不能据此宣称全部交付。**

两项明确未通过：

1. **强制安卓权限隔离未实现。** Colima 默认网络允许容器自行连接 Mac loopback ADB 5037。`hostAndroidDevices` 仅决定是否提供共享通道，不阻止恶意代码绕过该通道。令牌鉴权与拒绝首条 `host:kill` 测试通过，不等于原始 ADB 旁路被封锁。只用于可信应用。
2. **GUI 冷启动 Colima 的文件共享不通过，已禁用此路径。** 曾观察 VM/容器 Running，但随后共享目录 stat、容器创建和 guest SSH I/O 阻塞，普通停机也阻塞；不能把 Running 当作前端/文件系统可用。已强制结束仅属于 `okdocker` 测试 profile 的 VZ hostagent，恢复由终端正常启动的运行时。恢复后完整回归通过。根因尚未定位，不把它武断归结为 TCC，也没有关闭/自动批准系统权限。当前 Colima 按钮只给启动说明，登录策略等待外部运行时就绪。

## 环境与测量方法

- Apple M4，10 CPU 核，16 GiB RAM；arm64。
- macOS 27.2（26B123）、Xcode 27.2、Swift 6.4.2；包最低部署 macOS 15，Swift 5 language mode。
- Homebrew 安装：Colima 0.10.3、Lima 2.3.0、Docker CLI 29.9.3、Compose 5.7.1；本机 Docker server 29.5.2。
- 独立 profile/context：`okdocker` / `colima-okdocker`，VZ + virtiofs；整台共享 VM 为 4 vCPU / 6 GiB / 80 GiB 虚拟磁盘容量，不是逐应用配额或宿主实际占用数字。
- Rust、Debian、Python 基础镜像固定 digest；Cargo 使用原工作树的 Cargo.lock + `--locked`，四项顶层 Debian 包固定版本，完整 dpkg 清单留在镜像内 `/usr/share/okdocker/package-versions.txt`。未声称所有 Debian 传递依赖都可永久从当前镜像站重现。
- 被测 xhs 镜像：`sha256:c82c50724c00726060504d4b39095ab8c9777bfd969093be7c41ba26b019236f`；基于当前含用户未提交改动的源码快照，而不是只按 HEAD 构建。镜像不含真实 Key、SQLite 或生产素材。

所有通过项来自本机真实进程、Docker inspect、HTTP、磁盘文件或已授权手机，不是模拟返回值。强杀用忽略 SIGTERM 的真实容器验证，检查退出码 137，并核对实际 running=0；8 秒仅是测试超时门槛，不是性能基准。

## 最近完整回归：通过范围

### Swift：17 项

`swift test`：有效配置、目录/符号链接越界、特权字段、未知嵌套权限、外部 Dockerfile、端口冲突、端点引用、URL 限制、Compose `$` 字面值、宿主 wildcard/loopback LISTEN 占用检查。

证据：`artifacts/swift-test.log`。

### 真实 Docker 生命周期：28 项

`python3 tests/integration.py`：

- 两个独立应用真实启动；配置文件试图开启自动启动仍默认关闭。
- 挂载只指向各自目录，兄弟标记文件与 Docker socket 不可见，端口只绑定 127.0.0.1。
- 默认不注入 ADB；没有将此项扩大为强制设备隔离。
- 环境中的 `${SECRET}` 和 `$` 不展开 Mac 环境，目录 `.env` 不能改变项目/Compose 来源。
- 写入文件、SIGKILL 关闭、容器退出码 137、实际停止、重启后数据保留；另一个项目持续可访问。
- 配置权限变化需重新导入；即使配置已变化仍可强杀旧实例。
- 取消进行中的构建；杀死启动器父进程后，显式关闭仍能撤销只属于该项目的孤儿 Compose 客户端，不会稍后又启动。
- macOS `0.0.0.0` wildcard 监听占用时，在任何应用容器创建前拒绝启动。

证据：`artifacts/validation/report.json`、`artifacts/integration-test.log`。

### 实际流水线 Linux 部署：21 项

`python3 tests/xhs_integration.py`：隔离目录、18865 端口、新 SQLite、无真实 Key、无素材/任务；流水线始终暂停。网页、health、Linux aarch64 进程、FFmpeg、SQLite 设置写入及 SIGKILL 后持久化、重启保持暂停、Android sidecar 均已验证。

本机当时有 **7 台已授权在线安卓设备**：与 Mac 原生 ADB 列表核对，通过 Linux client 做只读 getprop 和完整 PNG 截图字节传输；有手机会在 PNG 前输出 warning，按实际服务已有的 PNG 签名提取逻辑核验，截图没有保存或输出。Mac 工具仍可列举设备，共享 ADB server PID 保持 **5617**。

没有真实 AI 请求、发帖、APK 安装、输入注入、账号切换或完整发布自动化。没有发送测试流水线的 start-publishing 请求。

证据：`artifacts/xhs-validation/report.json`、`artifacts/xhs-integration-test.log`。

### 原生窗口与登录策略

`python3 tests/ui_smoke.py`：

- 实际 NSWindow 可见、菜单栏存在、关闭窗口保留菜单栏、重新打开窗口。
- 捕获的是本应用自身视图，不录制用户桌面或其他应用。
- 系统 SMAppService 从关闭注册为 enabled，再注销恢复关闭；应用自动启动开关持久化。
- **运行时由终端预先正常启动**，重新启动 UI 能按登录策略启动 fixture，退出 UI 后容器和实际网页内容均仍可访问。
- 结束清理自动启动与系统登录项，默认两个登记应用均关闭自动启动。

没有真的注销 Mac 账号；不是 FileVault 解锁前的开机服务验收。右键操作已实现，但未把它描述为完整 AX/XCUITest 端到端点击覆盖；系统权限提示、其他 macOS/硬件/运行时也未全测。

证据：`artifacts/ui/native-ui.json`、`artifacts/ui-smoke-test.log`、`artifacts/login-self-test.log`。

## 风险回归与一次已清理的防护探针

发现 Darwin 的 SO_REUSEADDR 可能让特定地址 bind 成功，即使已有 wildcard listener，因此只尝试 bind 是错误的端口占用判断。修复为先检查真实 LISTEN socket，镜像构建/拉取之后再次检查，再以 `--no-build --pull never` 创建应用。

修复前的一次原目录端口防护探针被取消：**仅创建了未启动的 ADB sidecar；没有创建流水线容器，没有挂载生产数据。** 已核对 Docker inspect 的 created/零时间状态并删除 sidecar/项目网络，停止该项目的桥和启动客户端。之后用隔离应用和独立 wildcard socket 做回归，不再拿生产数据目录试探此错误。

同时修复启动取消只依赖活着的父进程的问题：关闭会撤销匹配唯一项目 + 私有 compose 路径的 Compose 客户端，锁 FD 使用 CLOEXEC。不会杀 Docker daemon、共享 ADB 或其他项目。

证据：`artifacts/production-guard-incident.json`、`artifacts/production-guard-cleanup.json`；探针没有流水线容器日志，sidecar 从未启动。

## 生产恢复与 Key 迁移

- 用户要求的 Key 已复制到 `xhs-liushuixian/apikey.md`，0600、Git 忽略；原父目录文件保留，不再作为程序默认来源。
- 此前已正常暂停/收尾、在线备份 SQLite、保存本机密钥、正常关机重启并比较业务表；`businessTablesUnchanged=true`，恢复原开启状态。
- 当前宿主进程 **67077** 提供 `http://127.0.0.1:17865`，`running=true`、`apiKeyConfigured=true`；共享 ADB server 仍为 5617。
- 本轮 Docker 验证没有替换/重启宿主服务，测试数据与真实数据分离。Docker 生产登记保留为关闭，登录自动启动关闭。
- 所有测试容器结束后关闭；专用测试 VM 停机以归还宿主内存，镜像/配置保留方便后续使用。未停止其他项目、未移交手机 USB 所有权。

证据：`artifacts/key-path-restart/restart-report.json`、`artifacts/restoration.json`。`artifacts/key-path-restart/` 含私密备份和原进程环境，**不要分享或提交 Git**。

## 复验

先按 README 正常启动运行时并确认宿主目录可用；不要启用已禁用的 GUI 冷启动路径：

```sh
bash scripts/build-app.sh
swift test
python3 integrations/xhs-liushuixian/prepare.py ../xhs-liushuixian
python3 tests/integration.py
python3 tests/xhs_integration.py
# 先关闭已有 OkDocker UI；脚本会保护既有登录偏好并恢复自己的修改
python3 tests/ui_smoke.py
```

运行期 fixture 在本应用 Application Support 的 `Validation/`，只放显式暂存的测试代码与新数据；维护源码/模板和报告在本仓库。不要为了测试授予整个主目录或关闭包签名、TLS、文件摘要、TCC。真实生产切换请遵循集成 README 的暂停、备份、正常停原服务和禁止双写流程。
