[English](../../docs/ARCHITECTURE.md)

# 架构与边界 · 0.3

默认链路是 **OkDocker → Apple container 1.7.1 CLI → 官方 Containerization / Virtualization.framework**。每容器独立 Linux VM；不是 Colima 中运行 Docker，也没有将 Linux 容器伪装成 macOS 原生进程。官方运行时单独签名安装，不内嵌未签名服务，不重写 vminitd。

## 模块职责

- `Models.swift`：schemaVersion 1、目录审批/路径约束与配置摘要。未知权限、越界、特殊文件、非法端口/URL 均拒绝。
- `Runtime.swift`：唯一注册表、原子写入、默认后端升级/备份、显式迁移、启动/关闭锁、取消标记及实际端口占用保护。按登记的后端分发。旧 Compose 代码只保留兼容关闭/观察/清理和 CLI 显式使用，不作为默认路径。
- `AppleRuntime.swift`：新增的官方 CLI 适配。负责参数数组、OCI 构建/镜像、带标签的容器与网络、inspect 审计、实际状态和 KILL。现有 Docker/Compose 接线无法承接 Apple 的 XPC/CLI 与每容器 VM 语义，所以分离此适配，不复制注册表和策略锁。
- `VersionDeployment.swift`：版本变化时准备新镜像/停止态容器、保留旧层、停止旧服务并原子选择新部署。复用 Runtime 的唯一操作锁/取消与 AppleRuntime 的启动/审计，不复制生命周期状态机；从适配器分离以避免镜像准备、数据保留与注册表提交交织。
- `BuildRecipe.swift`：官方构建器没有项目脚本钩子，因此仅在私有临时 Dockerfile 的指定阶段注入脚本 RUN，保留原 context 与 Dockerfile 专属 ignore；不修改原文件、不执行宿主 shell。
- `AppModel.swift`：异步编排、采样、独立 HTTP 就绪探针、SMAppService。旧卡片显式迁移，不能因换默认后端悄悄启动另一份部署。
- `Views.swift` / `Entry.swift`：SwiftUI/AppKit 启动器、菜单栏、导入审批、设置及 CLI。主线程不执行镜像构建或 Docker/Apple CLI。
- `LANAccess.swift`：用户独立授权的宿主 TCP 入口与进程身份检查；只转发指定应用的已审批前后端 loopback 端口到当前私有 Wi-Fi/以太网 IPv4。独立助手在 UI 退出后保留，开关/关闭仅影响自己的入口。直接改 Apple 发布参数需替换现有容器并丢失未挂载可写层，所以不能由原部署适配承担；不为此修改配置摘要或重建 VM。
- `AndroidBridge.swift`：每应用独立令牌助手。Apple 路径只监听当前用户私有临时目录的 Unix socket；legacy Docker 保留 loopback TCP 模式。共享 Mac ADB 仍只在原 `127.0.0.1:5037`，不转移 USB/ADB 凭据。
- `Resources/Android`：静态 Linux arm64 转发程序。Apple 后端容器以它作为持续运行的入口：先监听本容器 `/run/okdocker-adb.sock`，验证自身挑战应答及真实宿主 ADB 版本，再作为子进程启动镜像原命令。入口转发停止信号，业务退出时一起退出，不自动重启业务。每个新连接重读令牌。启动检查真实转发协议，不能只看 socket 能连上或 VM 是 running。旧版先拉子进程再 exec、同时设置父进程死亡信号，可能在 exec 时因父线程消失而杀死转发；这套组合已经移除。地址不随 VM IP 改变。不开放手机桥 TCP，也不改 PF/DNS/Private Relay。旧 sidecar 只为已创建的旧容器保留。
- `scripts/install-app.py`：显式本机升级、旧包备份与原子替换；与只构建 dist 的脚本分开，避免每次打包悄悄替换运行中的应用。既不修改登录设置，也不启停运行时/容器或清除系统隔离属性。

## 生命周期与持久化

关闭窗口保留菜单栏；退出 UI 保留服务。重开从 `container list --all --format json` 恢复实际状态，再检查 HTTP。Running 不是目录/网页/ADB 都健康的证明。

每应用使用唯一项目名及应用 ID + support 路径摘要标签；网络同样校验所有权。停止/删除不使用 `--all`。强制关闭发送 KILL，撤销该项目启动/构建客户端，等待启动锁，再核查实际 running=0；不停止共享引擎、构建器或 ADB。官方 `container build` 会 exec 为 build 插件，孤儿取消必须匹配该插件路径及项目/支持目录标签，不能只找 `container build` 进程名。

应用 `version` 与 `schemaVersion:1` 独立。同版本停止/启动复用原容器；新版本先为所有应用服务使用唯一部署名/镜像标签，以 `--no-cache --pull` 构建，或对 image 服务重新 pull。新容器创建后审计、保持停止；旧服务先 SIGTERM（上游 30 秒超时后 KILL），确认停止及端口空闲后，原子提交 `AppRecord.deployment` / `manifestVersion` / `manifestHash`，然后通过原有启动路径激活。没有旧新服务并行写挂载目录的切换窗口，构建失败不停止旧服务。

提交前中断只留下停止态候选；提交后中断，下次启动继续选中的新代际。所有版本的旧容器可写层/镜像保留，私有 deployments 文件夹保存切换前登记，CLI deployments 读取实际状态。选中代际用于观察、日志、LAN 发布者识别，关闭和移除则遍历同应用/同支持目录的所有拥有资源；不遗漏旧代际。新建版本的 ADB 转发在新后端容器内启动；旧 sidecar 虚拟机在新部署成功后停止，不自动删除。新容器不继承旧可写层；挂载数据继续使用但不是快照，不做自动数据回滚。移除会删除所有代际未挂载可写层，宿主目录不动。

AppRecord 新字段均可选，兼容旧注册表；格式仍为 2，首次运行先保存 registry-before-versions.json 私有备份，不重置登录/LAN 偏好。`approvalHash` 对规范化 Manifest 排除 version 后编码摘要；其余所有字段仍为审批整体。只有版本可变化时复用授权，运行时 LAN/autostart 许可不受部署提交覆盖。旧基线仅在原摘要仍匹配时补齐，无法验证则须显式重新导入；同版本但实际配置摘要不一致仍拒绝。长时间构建后重查配置、版本、登记和取消标记；不把修改源码本身当成版本检测或文件系统快照。

局域网许可保存在 `AppRecord.lanAccess`（可选字段，缺失即关闭），不接受来自导入 manifest 的自动授权。新增 `--cli lan ID on|off|status`；新连接核查原发布者 PID、启动时间、命令与 loopback LISTEN，拒绝复用其他服务的端口。私有地址变动重新绑定并断开旧连接；不保证公网转发设备或其他代理的安全性，认证由应用实现。关闭入口不改容器，停止容器先关闭入口，防止迟到转发。

## 信任与边界

CLI 不经 shell，不继承 `CONTAINER_*` / Docker 端点覆盖，不读取应用 `.env`。只传明确目录、平台、网络、端口、命令与完整 `KEY=value`；`build.script` 相对构建 context 的普通文件，Dockerfile 的唯一独立标记被替换为 JSON exec 形式的 Linux shebang 解释器与相对脚本路径（无 shebang 时 `/bin/sh ./相对路径`），仅在 Linux 构建阶段执行，COPY/WORKDIR/工具链和最终运行镜像由项目声明；源目录/目标含 CLI 分隔字符则拒绝。创建完成、启动之前审计实际配置，不把命令成功当成已授权。

应用不能提交 privileged、外部网络/卷、host PID/network、socket/设备、SSH/home 共享或自定义内核/运行时。Apple 接线不支持的单文件绑定不会偷偷扩大为对父目录的授权。ADB 的宿主 socket、只读令牌目录和转发程序仅在显式授权后注入获准后端容器。旧 sidecar 仍须去掉全部 capabilities。宿主令牌目录保持只读。

同 UID 的恶意宿主程序、宿主管理员和有权控制官方运行时的人不在防御范围；并发路径替换也不是已完成强沙箱。每应用独立 vmnet 不等于完整出站防火墙。安卓仍只支持可信代码，不用历史 Colima 旁路结果冒充 Apple 网络验证。

不强制用户填写资源配额，但官方 VM 默认容量及构建器资源仍存在。没有重写弹性资源管理，也不承诺活跃 guest 释放内存必定归还 Mac。详见 [迁移决策](APPLE-BACKEND.md) 与 [分后端验证记录](VALIDATION.md)。
