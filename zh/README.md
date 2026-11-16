[English](../README.md)

# OkDocker

基于 Apple [container](https://github.com/apple/container) 的原生 macOS 容器应用管理器。

把应用文件夹添加到 OkDocker，即可在启动器和菜单栏中管理服务：启动、打开网页、查看状态和日志，或按需开放局域网访问。

![OkDocker 启动器](docs/images/launcher.png)

## 功能

- **原生界面**：SwiftUI / AppKit 构建，支持 Liquid Glass、图标网格、搜索和菜单栏操作。
- **文件夹导入**：通过 `okdocker.json` 定义应用名称、图标、镜像或 Dockerfile、启动命令、目录挂载及前后端端口，支持多服务应用。
- **版本部署**：配置应用 `version`；版本变化时从源码重新构建、切换到新容器，保留已停止的旧部署。可用 `build.script` 接入项目自己的 Linux 构建脚本。
- **应用管理**：点击图标启动或打开网页，右键查看日志、调整设置、强制关闭或移除应用。状态结合实际容器信息与 HTTP 探测显示。
- **局域网访问**：每个应用独立开关，可查看、打开和复制 Mac 的局域网地址，无需重建运行中的容器。
- **登录启动**：支持管理器和单个应用的登录自动启动，默认关闭。
- **安卓接入**：应用可选择通过共享 ADB 访问 Mac 已授权的安卓设备，Mac 上的其他 ADB 工具仍可使用。
- **配置规则复制**：在应用内查看完整配置文档，一键复制给 AI，辅助生成项目的配置文件和 Dockerfile。

## 实现原理

```text
SwiftUI / AppKit 界面
        │
应用注册表、配置校验与生命周期管理
        │
Apple container CLI
        │
Containerization / Virtualization.framework
        │
每个容器独立的 Linux 虚拟机
```

OkDocker 使用 Swift 编写，通过 Apple 官方 CLI 完成 OCI 镜像拉取、Dockerfile 构建和容器管理。运行应用不需要 Docker Engine、Compose 或 Colima。目前适配 **container 1.7.1**，支持 Linux arm64 镜像。

- **目录与配置**：导入时检查相对路径、挂载范围及端口，并保存配置摘要；启动前再次校验。宿主挂载限定在应用目录内，不默认共享整个用户主目录。
- **运行与数据**：每个应用使用独立网络和所有权标签，管理操作只针对该应用的容器。相同版本停止后再次启动复用原容器；版本变化则构建新镜像并切换部署，旧容器停止保留。新容器不自动继承旧可写层，持久数据应显式挂载。
- **局域网入口**：容器端口仍发布到 `127.0.0.1`。开启局域网访问后，独立的原生 TCP 助手将其转发到 Mac 当前 Wi-Fi / 以太网的私有 IPv4 地址，因此不需要修改容器配置。
- **安卓通道**：通过私有 Unix socket 和带令牌的宿主助手连接 Mac ADB。新建的 Apple 容器把转发程序放进获准的后端容器，不另开虚拟机，也不把 ADB 端口开放到局域网，不转移 USB 设备所有权。
- **后台运行**：界面与容器、转发助手分开运行；关闭主窗口或退出管理器不会中断已运行的服务。登录启动使用系统 `SMAppService`。

## 安装

### 环境要求

- Apple Silicon Mac
- macOS 26 或更新版本
- Apple [container 1.7.1](https://github.com/apple/container/releases/tag/1.7.1)
- 从源码构建需 Xcode 26 或更新版本，以及 Python 3
- 使用安卓接入时，Mac 需安装 ADB，设备需开启 USB 调试并完成授权

### 从源码构建

先安装 Apple container 的官方签名安装包，再在本仓库根目录执行：

```sh
bash scripts/build-app.sh
open dist/OkDocker.app
```

如需安装到应用程序目录：

```sh
python3 scripts/install-app.py
```

安装脚本会备份旧应用包并替换安装；优先使用 `/Applications`，无写入权限时使用 `~/Applications`。默认构建为 ad-hoc 签名，不是经过 Developer ID 公证的发行包。

## 使用

### 添加并启动应用

1. 打开 OkDocker，点击 **启动运行时**。首次使用时，Apple container 会下载 Linux 内核。
2. 在应用根目录准备 [`okdocker.json`](CONFIGURATION.md)。可以先导入仓库中的 [`examples/hello`](examples/hello) 体验完整流程。
3. 点击 **添加应用**，选择应用文件夹或配置文件，确认目录、端口和权限。导入只登记，不立即启动。
4. 点击应用图标启动。首次启动可能需要拉取镜像或构建，完成后再次点击图标即可打开网页。
5. 右键应用图标，可打开服务端地址、查看日志、进入应用设置或强制关闭。

为自己的项目准备配置时，可以在设置中打开 **配置规则**，点击 **复制完整规则给 AI**，再向 AI 提供项目结构和启动方式。完整字段说明及示例见 [CONFIGURATION.md](CONFIGURATION.md)。

### 更新应用与自定义构建

修改源码后，同步提高 `okdocker.json` 的 `version`，如 `1.0.0` → `1.0.1`，再点击启动或右键 **启动 / 检查版本更新**。版本变化时先无缓存构建新镜像，成功后停止旧服务、启动新容器；构建失败旧服务继续运行。相同版本不重复构建。仅打开网页不会触发更新。

不同项目可在 `services.<服务名>.build` 中指定 `script`：

```json
"build": {"context": ".", "dockerfile": "Dockerfile", "script": "scripts/build.sh"}
```

脚本相对构建上下文，在 Dockerfile 的 Linux 构建阶段运行，不直接在 Mac 执行。Dockerfile 需复制源码、准备工具链，在 `COPY` / `WORKDIR` 后放置 `# okdocker:build-script` 标记；最终运行镜像仍由 Dockerfile 定义。完整可运行示例见 [`examples/scripted-web`](examples/scripted-web)，详细规则见[配置文档](CONFIGURATION.md#自定义构建脚本)。

更新会短暂停机。挂载数据继续使用原目录，但旧容器的未挂载数据不会自动带入新容器；升级前请备份并处理数据格式兼容。旧部署保留以便恢复，积累的历史层仍占磁盘。仅用 `image` 的服务会重新拉取镜像并新建容器，不会从源码编译。

### 从局域网访问

在右键菜单或应用设置中开启 **允许局域网访问**，然后复制已就绪的地址到其他设备浏览器。

局域网访问默认关闭，目前支持私有 IPv4 的 Wi-Fi / 以太网接口，不包含 IPv6、VPN 或公网监听。客户端需能通过网络访问 Mac；应用接口的登录认证由应用自身提供。

### 关闭与数据保留

- **关闭主窗口**：保留菜单栏和运行中的服务。
- **退出 OkDocker**：保留容器及已开启的局域网入口。
- **强制关闭应用**：向该应用的容器发送 `SIGKILL`，保留文件与容器可写层，但会中断任务和写入，可能造成数据损坏。
- **移除应用**：删除登记和该应用所有代际的已停止容器，保留宿主应用目录；容器内未挂载的数据会随容器删除。

只改应用 `version` 可直接触发新部署；其他配置或授权目录变化仍须按[配置文档](CONFIGURATION.md)重新导入确认。旧登记缺少授权基线且配置已被修改时，也需重新确认一次。不会因升级静默删除旧可写层。

仅建议导入可信应用。目录挂载限制和安卓开关不等于完整的网络或设备沙箱；开启局域网访问也不会自动为应用增加身份认证。

## 命令行

GUI 和 CLI 使用同一份应用注册表：

```sh
APP=/Applications/OkDocker.app/Contents/MacOS/OkDocker

"$APP" --cli import /path/to/app
"$APP" --cli list
"$APP" --cli start <ID>
"$APP" --cli status <ID>
"$APP" --cli deployments <ID>
"$APP" --cli lan <ID> on
"$APP" --cli lan <ID> off
"$APP" --cli close <ID> --force
```

注册表及管理器配置存放在 `~/Library/Application Support/OkDocker/`。运行单元测试可执行 `swift test`。

## 更多文档

- [应用配置](CONFIGURATION.md)
- [架构说明](docs/ARCHITECTURE.md)
- [Apple container 后端](docs/APPLE-BACKEND.md)
- [第三方组件与许可证](THIRD_PARTY.md)

## 许可证

OkDocker 使用 [MIT License](LICENSE)。Apple container 及其他第三方组件遵循各自许可证。
