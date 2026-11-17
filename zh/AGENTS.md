[English](../AGENTS.md)

# OkDocker 工作约定

- 本目录是 OkDocker 唯一项目根目录；先读 README.md、CONFIGURATION.md 和 docs/ARCHITECTURE.md。
- 产品是原生 macOS 菜单栏 + 启动器窗口，使用 SwiftUI/AppKit；不把其他 codebox 项目改成此项目的源码目录。
- 默认后端是 Apple container 1.7.1 官方 CLI（macOS 26+ / Apple Silicon），不是 Colima/Docker context；CLI 适配不重写 vminitd。先读 docs/APPLE-BACKEND.md 与 docs/VALIDATION.md。旧 Docker 仅兼容观察、关闭、清理和显式迁移。
- 管理器与具体应用业务无关，UI 与通用配置规则不放特定业务的提醒或控制逻辑。集成示例和隔离验收不得因此触发真实业务。
- LAN 默认关闭，只由用户在每应用设置/CLI 显式授权，manifest 不自动授权。容器仍只发到 loopback；独立助手仅监听物理 en* 私有 IPv4，核验原本地发布进程，禁止转发已被其他服务复用的端口。不重建 VM 或静默改系统防火墙。
- 默认仅授权导入应用目录；启动前审计实际 Apple inspect（旧 Docker 审计完整展开 Compose），拒绝越界挂载/构建、任意 socket、privileged、host PID/network、外部网络/卷等隐式越权。配置不是任意宿主 shell 脚本。只有显式安卓授权允许固定的私有 socket/只读配置目录例外。
- 关闭应用按用户要求强制杀死该应用的容器，明确提示数据写入风险；不删除数据卷，不停止其他项目或共享 ADB。
- 登录自启动默认关闭。启动 HTTP 服务不等于授权应用去执行真实外部操作。所有状态来自容器和 HTTP 的实际观测，不伪造 ready。
- 安卓接入是独立显式授权，只桥接 ADB，不承诺 Mac 全部硬件直通或完全隔离。不能开放无鉴权 ADB 到局域网。
- 升级先备份注册表，不自动把旧登记当已迁移或已停止。同版本停止/启动保留可写层；应用 version 改变时先复用依赖缓存并重新构建应用镜像，停止旧部署后切换新容器，旧层保留不自动删除。版本以外配置变化仍须重新审批；持久数据显式挂载、升级前备份，不自动做数据回滚。build.script 只能在 Dockerfile 的 Linux 构建阶段执行，不能变成任意宿主 shell 钩子。
- 依赖锁定，记录来源与许可证；未实际运行验证的能力不能标为通过。系统本地网络/目录授权须用户正常批准，不改 TCC/PF 绕过；不能把“Running”当网页与挂载就绪。
