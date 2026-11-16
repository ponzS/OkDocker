[English](../../docs/VALIDATION.md)

# 本机验证记录 · 0.3 Apple container 验证版

## 0.3.1 容器内 ADB 生命周期修复（2026-11-17）

0.3.0 的 exec/父进程死亡信号组合在新的隔离测试第一次启动时即可复现失败：启动后立即查询 ADB 的业务进程拿不到就绪通道。手动拉起转发不是持久修复。

现在转发作为同容器内常驻入口，先绑定并验证本地转发协议及真实宿主 ADB，再启动业务；转发停止信号，随业务一起退出，每个新连接重新读取令牌。OkDocker 在启动后核验完整通道；对运行中的应用显式再次启动时，也会修复缺失的宿主桥。不自动重启业务，不另开虚拟机。

本机验证结果：

- **73 项 Swift 测试**通过（`artifacts/adb-fix-swift.log`）。
- Go 行为测试在 macOS 以 `-race` 通过，也在真实 Apple 虚拟机里以 Linux arm64 测试程序通过：协议帧、令牌轮换、不把返回空列表的普通 ADB 服务当转发、半关闭后完整响应、残留 socket 替换，以及 5 次入口启动/TERM 周期。
- **33 项隔离升级/生命周期检查**通过（`artifacts/android-upgrade-fix.log`、`artifacts/android-lifecycle/report.json`）：旧管理器创建的容器不重建、不丢可写层即可用新转发启动；连续 4 次强制关闭/启动后立即查询 ADB，列表与 Mac 一致；仅一台应用 VM；宿主桥重建和令牌重读期间，guest boot ID、业务 PID 和启动时间不变；错误令牌和共享服务关闭请求拒绝；私有 socket；TERM 正确传递，状态确实停止。
- **30 项核心集成检查**通过（`artifacts/adb-fix-core.log`）。

共享 ADB 只收到 `host:version` 和 `host:devices-l`，未进行手机 shell、截图、输入、安装或业务操作。共享 ADB PID 和全部既有容器状态不变，测试资源清理无错误；未挂载真实应用数据或配置。这不是任意宿主崩溃自动恢复验收：显式启动可重建宿主桥并让运行中转发读取新令牌，但没有自动宿主 watchdog。已有容器内转发的应用用新版管理器关闭再启动一次即可升级，不必改业务版本或重新构建业务镜像。

## 0.3 应用版本与构建脚本（2026-11-16）

环境沿用本机 Apple M4 / 16 GiB / macOS 27.2 / Apple container 1.7.1，官方每容器 Linux arm64 VM。以下均为独立 fixture、端口和私有注册表，不部署或挂载生产目录。

- **71 项 Swift 测试通过**（原 51 + 20）：应用 version 与 schemaVersion 分离、版本字符串/旧登记兼容、版本排除后的完整授权摘要、实际容器版本对比、代际命名长度与唯一性、脚本路径/符号链接边界、JSON exec 参数、Linux shebang 与默认 sh、唯一构建阶段标记、原 Dockerfile 不变、Dockerfile 专属 ignore 保留及临时文件清理。`artifacts/version-swift-test.log`。
- **31 项真实版本/脚本检查通过**：两个应用；Shell 与 Python shebang 真实 Linux 打包并返回构建产物；Dockerfile/宿主未执行脚本；相同版本运行/停止重启复用；版本变化新镜像引用与新容器；仅版本变化仍生成新的 UUID 产物（okdocker.json 已排除出构建上下文，验证无缓存 RUN）；版本降级也重新构建；旧层停止保留并能在当前服务停止后恢复读取；新容器不继承旧层；宿主挂载保留；部分停止的选中代际可继续；失败脚本/构建中版本再改不停止旧服务；版本不能越过端口授权；原授权 LAN 助手转到新发布者；ADB Unix 通道仍可用；普通与 Dockerfile 专属 .dockerignore 均生效；旧登记安全补授权基线；关闭/移除覆盖全部代际且不改其他容器的观测状态。`artifacts/version-validation/report.json`、`artifacts/version-integration-test.log`，清理错误为空。
- **核心 30 项 / 取消 7 项回归通过**：`artifacts/version-core-regression.log`、`artifacts/version-cancellation-regression.log`。取消仍用真实 build 插件/孤儿客户端及延迟检查，不停止共享运行时或 builder。
- **0.3.0 已安装到 `/Applications/OkDocker.app` 并复测**：旧 0.2.1 包先备份，签名和构建可执行文件一致；ad-hoc 签名而非 Developer ID 公证。已安装程序重跑版本/脚本 **31 项**、核心 **30 项**、取消 **7 项**；原生安装验收 **12 项**：真实主窗口/菜单栏/关闭重开、规则与带配置版本的应用设置、脚本示例由 GUI 启动、旧服务运行时 GUI 启动检查新版本并真正切换 HTTP 内容、UI 退出保留服务、规则与源码一致、原有应用登记及全局登录偏好不变。仅用隔离注册表策略测试自动启动，不更改 SMAppService。`tests/installed_smoke.py`，`artifacts/version-installed/report.json` 与 `version-installed-{core,cancellation,versions}.log`。
- 本轮未重启用户现有应用或改其源目录/配置，未进行完整 GUI 逐项点击、真实注销登录、手机 LAN、性能或数据库升级回滚验收。界面检查发现设置说明会截断，已改为完整换行后复验；截图仅自己的 fixture 视图。

ADB 此轮只发送 `host:version` 检查通道，不枚举/操作手机；LAN 只从 Mac 请求自身私有地址，**不替代下述物理手机网络未通过的结论**。保留旧层不是挂载数据快照，没有声称自动迁移数据、自动回滚或断电事务验收通过。模板源码暂存规则已更新，但未对相邻实际应用运行生成/安装，也未修改其生产配置。

复验：

```sh
swift test
bash scripts/build-app.sh
python3 tests/apple_versions.py
OKDOCKER_BIN="$PWD/dist/OkDocker.app/Contents/MacOS/OkDocker" python3 tests/apple_integration.py
python3 tests/apple_cancellation.py
# 已安装副本：不停止共享运行时或更改系统登录项
python3 tests/installed_smoke.py
OKDOCKER_BIN=/Applications/OkDocker.app/Contents/MacOS/OkDocker python3 tests/apple_versions.py
```

---

## 0.2.1 局域网与规则复制（2026-11-16）

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
- **原生 UI 与真正冷运行时**：正常 SMAppService 注册/注销恢复原关闭偏好；在共享运行时没有其他工作时先正常停止服务，由 GUI 启动官方运行时、自动启动独立 fixture、读取实际挂载网页内容；主窗口/菜单栏、关闭重开、仅捕获自身视图、UI 退出后网页仍可访问，测试资源最后关闭移除。没有实际注销 Mac 账号。`artifacts/apple-ui/report.json`。

### 明确限制与排障记录

1. 官方运行时首次内核下载 TLS 中断；改为正常 TLS 下载同一官方归档，并同时以官方 SHA256 和 `container system kernel set --digest` 校验，没有关闭签名/TLS/摘要。签名安装包 Apple 公证可信；这不等于 OkDocker 本身已做 Developer ID 分发公证。
3. vmnet 网关不是可直接绑定的 Mac 接口，未采用对 LAN 开放监听的变通。0.2 的 ADB 使用独立 sidecar 和官方 Unix socket。当前新建部署改为在获准后端容器内转发，不再为手机桥单独开虚拟机。宿主令牌目录保持只读。0.2 记录里的独立 VM helper 只说明当时的实现，不是当前新建容器的布局。
4. Android 开关不承诺恶意出站强隔离；官方自定义网络没有 Compose 式裸服务名发现；单文件挂载不会自动扩大为父目录授权。镜像源码变更需明确备份/重建，不做静默删层或源码热更新。
5. 官方每 VM 默认 4 vCPU/1 GiB，构建器默认 2 vCPU/2 GiB；不是固定宿主预占，也不等于无限弹性。没有完成多负载内存回收性能验收，不承诺一定比 Colima 更省内存。官方构建器自己的 privileged guest/Rosetta 支持是上游实现；产品工作负载明确 arm64、不开 Rosetta，不给应用自定义这些权限。

### 生产保护


### 0.2 复验

```sh
bash scripts/build-app.sh
swift test
OKDOCKER_BIN="$PWD/dist/OkDocker.app/Contents/MacOS/OkDocker" python3 tests/apple_integration.py
python3 tests/apple_cancellation.py
python3 tests/apple_android.py
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


同时修复启动取消只依赖活着的父进程的问题：关闭会撤销匹配唯一项目 + 私有 compose 路径的 Compose 客户端，锁 FD 使用 CLOEXEC。不会杀 Docker daemon、共享 ADB 或其他项目。


## 复验

先按 README 正常启动运行时并确认宿主目录可用；不要启用已禁用的 GUI 冷启动路径：

```sh
bash scripts/build-app.sh
swift test
python3 tests/integration.py
# 先关闭已有 OkDocker UI；脚本会保护既有登录偏好并恢复自己的修改
python3 tests/ui_smoke.py
```

运行期 fixture 在本应用 Application Support 的 `Validation/`，只放显式暂存的测试代码与新数据。不要为了测试授予整个主目录或关闭包签名、TLS、文件摘要、TCC。
