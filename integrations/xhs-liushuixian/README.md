# 小红书流水线集成

OkDocker 0.2 默认使用 **Apple container 1.7.1**；不是 Docker context 的别名。模板的 Dockerfile 是 OCI 构建描述，可由官方 `container build` 使用。旧 Docker 登记只在确认旧实例停止后显式迁移，迁移登记不等于上线容器。

模板将现有 Rust 服务编译成 Linux ARM64 二进制，不使用宿主 Mach-O 文件。FFmpeg、Linux ADB、CA 和 tzdata 在镜像内；页面/APK/持久数据来自明确授权的项目目录，不复制 Key 或业务库进镜像。

## 部署约定

以下为模板默认约定，不代表某台机器的当前运行状态；切换前须重新核查：

- 前端：`http://127.0.0.1:17865/`，目录 `public/`。
- 服务端：`http://127.0.0.1:17865/health`，目录 `server/`。
- `hostAndroidDevices: true`，使用全部已授权安卓手机的共享 ADB。
- 模板不启用登录自动启动；生成配置或导入不启动容器，也不停止原宿主服务。
- API Key 使用项目内 `apikey.md`；该文件 0600、Git 忽略，不再默认读取父目录。
- 宿主路径按原绝对项目路径挂到容器内，避免项目内素材/工具路径因改成 `/workspace` 而全部失效。项目目录之外的素材不开放；先移入项目内并调整业务设置，不能因此授权整个 `codebox/`。

## 将来手动切换到 Apple container

1. 在原工作台暂停流水线，等待活动/维护/预览/导入任务全部收尾，记录原状态。
2. 对 SQLite 做在线备份/正常停服后的完整备份，并保存本机加密密钥、上传和证据数据；不要只复制运行中的主 DB。
3. 正常关闭原宿主服务，确认 17865 已释放。**不能只关浏览器/终端窗口，也不要同时运行两套服务写生产库。**
4. 源码变化后，重新生成只包含 Rust 源码与 Cargo.lock 的构建快照；已有配置会拒绝覆盖，确认后才能加 `--replace`：
   ```sh
   cd /path/to/OkDocker
   python3 integrations/xhs-liushuixian/prepare.py ../xhs-liushuixian --install --android --replace --app-version 1.0.1
   ```
   后续每次源码更新也必须重新执行暂存，并改变 `--app-version`；仅修改源项目代码而未刷新 `.okdocker-build` 不会更新构建输入。`version` 变化可触发 OkDocker 0.3 的新镜像/新容器部署；模板原有 Cargo 构建步骤仍在 Dockerfile 中，不要求额外脚本。其他配置/权限变化先关闭并重新导入。升级前备份应用数据；旧层保留不等于数据库快照。
5. 安装官方 Apple container 1.7.1，在 OkDocker 启动运行时；正常批准 macOS 本地网络/目录访问提示。旧登记先确认 Docker 实例停止并迁移。如果配置/权限改变，重新导入确认；已有不同摘要的容器不会自动删除，须先备份其未挂载数据后明确移除。点击图标启动；随后浏览器打开工作台。
6. 新服务本身默认暂停发布。确认 Key、设备、素材和数据正确，再由你明确决定是否开始真实业务；登录自动启动不是发布授权。

端口被原服务占用时，OkDocker 在构建/创建容器前拒绝启动，不杀原服务。SQLite 还有自己的锁，但不能只依赖跨宿主/虚拟机文件锁来防止双写。

## 关闭和恢复宿主模式

最好先在流水线内暂停并收尾，再在 OkDocker 强制关闭（SIGKILL，不等待收尾、不删除数据）。确认该项目全部容器已停止后，使用原宿主启动方式恢复。项目路径保持一致，但不能保证强杀期间未完成文件写入无损；需要备份和业务校验。

历史 Docker 验证使用独立目录/18865；0.2 Apple 验证使用独立 `Validation/ApplePipeline/` 新目录与 19865，始终暂停、无 Key/业务任务。这些是历史隔离测试，不代表当前宿主或容器状态。Key 路径迁移属于单独维护操作，不是模板生成或版本更新自动执行的功能。

## 已测与未测

0.2 Apple 后端已验证实际 Linux 网页/API、arm64、FFmpeg、新 SQLite、SIGKILL 与设置持久化、Unix socket sidecar、当时在线的 2 台已授权手机列举与 Linux ADB 只读 getprop；没有保存或读取手机屏幕。历史 Docker 的 7 台手机和截图传输是不同轮次的证据，不能当作新后端硬件覆盖。**没有在容器里做真实 AI 请求、发布、APK 安装、输入注入或完整 UI 自动化任务**，这些不能按已通过计。

Linux 不能弹 macOS 的 osascript 文件夹选择器；现有服务会提示手填完整目录，目录必须在授权项目内。网页显示的容器网卡/LAN 二维码未做宿主 LAN 适配，本版使用上述 Mac loopback 地址。Apple ADB 使用 `localfilesystem:/run/okdocker-adb.sock`，无需把 Mac ADB 暴露到网络，也不依赖 sidecar 动态 IP。首次测试曾遇到官方端口转发 `No route to host`，打开系统本地网络设置提示正常授权后复验通过；没有改 TCC/PF，未单独确定是权限还是瞬态网络状态。无线配对/mDNS、其他 Mac 运行时和 ARM64 以外架构未验收。
