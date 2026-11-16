# OkDocker 应用约定（schemaVersion 1）

把 **`okdocker.json` 放在应用文件夹根目录**。在 OkDocker 点“添加应用”，选择该目录或此文件，核对授权后导入；点击图标启动，右键管理。导入本身不构建、不启动。请只导入可信代码。

## 最小示例

```json
{
  "schemaVersion": 1,
  "id": "my-service",
  "name": "我的服务",
  "icon": "icon.png",
  "autoStart": false,
  "hostAndroidDevices": false,
  "frontend": {
    "service": "app",
    "directory": "public",
    "path": "/",
    "hostPort": 18080,
    "containerPort": 8080
  },
  "backend": {
    "service": "app",
    "directory": "server",
    "path": "/health",
    "hostPort": 18080,
    "containerPort": 8080
  },
  "services": {
    "app": {
      "build": {"context": ".", "dockerfile": "Dockerfile"},
      "workingDirectory": "/workspace",
      "command": ["/usr/local/bin/my-server"],
      "environment": {"HOST": "0.0.0.0", "PORT": "8080"},
      "mounts": [{"source": ".", "target": "/workspace", "readOnly": false}]
    }
  }
}
```

先创建示例引用的 `public/`、`server/`、`Dockerfile` 和可选图标。没有图标可删除 `icon` 字段，界面会显示默认图标。`examples/hello/` 是可直接导入的示例。

默认后端为 **Apple container 1.7.1（macOS 26+ / Apple Silicon）**。此文件不是 Compose，也不接受任意 CLI 参数。旧 Docker 登记需显式迁移；应用数据不会因切换默认后端自动搬运。

## 字段与路径

| 字段 | 规则 |
|---|---|
| `schemaVersion` | 必须为 `1` |
| `id` | 小写字母开头，后接小写字母/数字/连字符，最多 48 字符 |
| `name` | 应用昵称，1–60 字符 |
| `icon` | 可选，相对本目录的 PNG/JPG/ICNS，低于 8 MiB；不能指向目录外 |
| `frontend` | 宿主浏览器打开的前端入口，必填 |
| `backend` | 宿主可访问的服务端入口/健康探针，必填 |
| `*.service` | 对应 `services` 中的服务名；前后端可以是同一个服务 |
| `*.directory` | 对应代码在宿主应用目录内的位置，必须存在。是来源说明/校验，不会执行其中脚本 |
| `*.path` | HTTP URL 路径，如 `/`、`/health`；不是宿主磁盘路径 |
| `*.hostPort` | Mac 访问端口，1024–65535；容器始终仅发布到 `127.0.0.1`，局域网入口由用户单独授权 |
| `*.containerPort` | 服务在容器内监听的 TCP 端口，1–65535 |
| `autoStart` | 默认 `false`。导入始终保持自动启动关闭；须在 UI 明确开启，文件不能偷偷注册登录项 |
| `hostAndroidDevices` | 默认 `false`；`true` 表示对**全部已授权安卓设备（含后续连接）**开放 ADB 接入，不是 Mac 全部设备直通 |
| `services` | 1–16 个服务，服务名只能用小写字母、数字、连字符；`okdocker-adb` 是保留名 |

前后端合并端口的场景应配置相同服务、相同宿主/容器端口但不同路径；前后端分离则分别引用对应服务和端口。容器内要监听 `0.0.0.0`，不是 `127.0.0.1`。默认不开放 LAN；不能把配置里的目录说明当作对某目录的自动额外授权。

## 局域网访问（管理器设置，不是配置文件权限）

在应用右键菜单或“应用设置”开启 **允许局域网访问**。默认关闭，导入配置不能自动开启；不要在 JSON 添加 `lanAccess`、`host` 或任意绑定地址字段。设置按已导入应用保存在管理器私有注册表，不改配置摘要、不重建容器。

- 原容器仍只监听 Mac `127.0.0.1:hostPort`；单独的原生 TCP 助手把此应用的**前后端端口**转发到 Mac 当前 Wi-Fi/以太网（`en*`）的私有 IPv4 地址（10/8、172.16/12、192.168/16）。不绑定 `0.0.0.0`、公网、VPN、虚拟网卡或 IPv6，不开放 ADB 端口。不代表网络防火墙或身份认证。
- 应用设置显示实际已监听的 Mac 地址，可打开或复制；右键“复制局域网地址”复制全部已就绪的前端地址。不要用容器内检测到的 VM IP 代替这个地址。前端应使用相对 API 路径或可配置服务端地址，不要向远端浏览器硬编码 `127.0.0.1`。
- 同网段设备可以访问所开放的应用接口，认证、账号和访问控制由应用自己提供。只在可信网络开启。正常批准 macOS 本地网络/防火墙提示；不自动改防火墙/TCC，也不做路由器端口映射。当前仅适配 Apple 后端。
- 开关不会重启或重建运行中的容器；关闭开关会断开转发连接，本机入口不变。关闭应用会关闭自己的 LAN 助手；退出管理器 UI 保留已授权的入口。下次启动应用/重开管理器会恢复已授权入口；停止状态只保存许可，不启动服务。
- 地址随网络变化重新绑定。每个新连接核查原本的 loopback 发布进程与端口身份，避免本地端口被其他服务重用后继续转发。无可用私有地址/端口冲突时如实显示失败，不扩大监听范围。

CLI：`OkDocker --cli lan <ID> on|off|status`。`on` 是明确授权前后端供同网段设备访问，不替应用增加登录密码。

## 服务配置

- `image` 或 `build` 二选一。分发时固定镜像 digest；`build.context` 相对应用根目录，`build.dockerfile` 相对 context；不得越界或用符号链接指向目录外。
- `command` 可选，为**容器内**可执行文件与参数数组，不是 Mac shell 命令；没有时使用镜像入口。Rust 等编译应用改代码后须重新构建，不承诺所有语言都自动热重载。
- `environment` 可选，字符串键值。建议凭据放在目录内权限 `0600` 且 Git 忽略的文件，不写进配置/镜像。`$` 按字面传入，不展开 Mac 的环境变量。
- `workingDirectory` 是容器内绝对路径。
- Apple 后端目前要求 `source` 为目录；不能自动把单文件挂载扩大成对其父目录的授权。含逗号/换行的路径会因 CLI 参数无法无歧义表达而拒绝，须先重命名。Apple 内部 ADB socket 是显式授权后的固定例外，配置不能自行指定任意 socket。
- `mounts` 默认 `[{"source":".","target":"/workspace","readOnly":false}]`。`source` 相对应用根目录；`readOnly:true` 为只读。空数组 `[]` 表示不挂宿主目录。目录须提前创建；拒绝越界、特殊 socket、系统设备目标。
- 每应用使用带所有权标签的独立 vmnet 网络，每容器独立轻量 VM。需要持久数据时，在应用目录内创建 `data/` 并显式映射。无需必填资源套餐；官方默认 VM 容量（4 vCPU / 1 GiB）仍存在，不是宿主预占。guest 空闲内存未必归还 Mac；默认 NAT 也不是阻止访问 Mac/LAN 的出站防火墙。
- 不提供 Compose 式裸服务名发现；不能假设容器内 `backend:8080` 自动解析。ADB 使用稳定 Unix socket，不依赖会变化的 VM IP。
- 使用上述受控声明格式，由管理器生成参数数组并在启动前审计实际 `container inspect` 的挂载、网络和端口。**不执行任意宿主启动/停止脚本，不导入任意 Compose YAML，不支持 privileged、Docker socket、外部网络、宿主 PID/network 或 USB 全设备映射。** 这避免“只访问本目录”的承诺被配置绕过。
- 修改配置后，先关闭应用、重新导入确认；启动前重新检查路径与配置摘要。如果已存在不同摘要的容器，启动会拒绝而不会静默删除可写层；先备份容器内数据，明确移除旧登记后重新导入。目录移动也需重新导入。
- 停止/启动重用原容器和镜像。修改源码要重新构建部署时，同样先备份并移除旧容器，再导入创建；不能把启动描述为源码自动热更新。

## 关闭、退出和自动启动

- “强制关闭应用”向该应用全部容器（含手机接入 sidecar）发送 **SIGKILL**，核验实际停止；**会中断任务和数据写入，可能造成数据损坏**。不删除应用文件/数据，不关闭其他项目或共享 ADB。
- 关闭主窗口保留菜单栏；退出 OkDocker 不停止容器。要停止服务须显式强制关闭。下次启动会重新观察容器，不把旧记录当成运行真值。
- 登录自动启动默认关闭。首次开启时注册系统 OkDocker 登录项，系统可能要求用户批准。没有批准就不把应用开关报成已开启。
- 自动启动是“登录 Mac 后，在运行时就绪时启动服务”；不是 FileVault 解锁前的开机守护。Apple 运行时支持由 GUI 启动，并以实际挂载文件和网页内容验收。首次需正常安装官方工具和内核、批准系统提示；旧 Colima 冷启动失败路径不会沿用。
- 不配置运行时自动重启策略，只有 OkDocker/SMAppService 的显式启动策略。进程崩溃如实显示，不静默无限重启。

## 安卓接入

镜像需包含 Linux ADB client。Mac 需有正常工作的 ADB。Apple 后端开启后加入项目私有 Python sidecar，使用官方 Unix socket 转发连接带随机令牌的 Mac 桥，再访问原 `127.0.0.1:5037`；应用使用 `ADB_SERVER_SOCKET=localfilesystem:/run/okdocker-adb.sock`。没有 TCP 接入监听、PF/DNS 修改、`~/.android` 挂载或 USB 所有权移交。

仅给获准后端额外挂载这一固定 socket；sidecar 只接入两个应用私有 socket 和一个只读令牌配置目录，drop ALL capabilities。官方 socket 发布无法看到 workload 独立 tmpfs 命名空间，所以 helper 使用其隔离 VM 的可写根创建 Unix socket，不将宿主目录改成可写。停止后可重用，不依赖动态 IP。

**安全限制：这个开关控制是否注入共享 ADB 通道，不是对恶意容器的强制设备权限。** 历史 Colima 网络已验证能绕过通道直接访问 Mac ADB；这不是 Apple 网络的通过或失败证据。新后端虽然不开放 ADB TCP 通道，仍未完成所有恶意出站/宿主端口旁路验收。令牌只保护自己的桥，不为 Mac 其他端口补鉴权。本版仍只支持可信应用，不承诺关闭开关即形成强制设备沙箱。目录挂载限制不等于网络访问限制。

手机仍需开启 USB 调试并正常确认信任、安装和输入权限。共享 ADB 的 Mac 工具通常可以继续用，但同时点击/输入/启动 instrumentation 会互相影响。桥拒绝首条控制请求 `host:kill`，关闭应用不调用共享 ADB 的关闭接口；client/server 版本必须兼容。不能把该开关理解为授权全部 Mac 硬件、目录或绕过手机授权。只把 `docs/VALIDATION.md` 明确列出的后端、硬件与只读操作算通过；其他运行时/手机能力需另行验收。

## 排查

0. Desktop/Downloads/外盘目录：macOS 首次可能要求访问批准。请通过应用的导入面板选择目录并正常批准；不关闭 TCC，不自动批准系统权限。
1. “引擎未就绪”：安装官方 Apple container 1.7.1，点击启动运行时。首次内核下载失败时保留签名/TLS/摘要校验后重试，不关闭校验。旧卡片先确认旧实例停止，再迁移登记；不要新建 Docker context 假装完成 Apple 迁移。
2. “端口被占用”：修改 `hostPort` 并重新导入，不会杀掉占用端口的其他程序。
3. “配置已改变”：先关闭，再重新导入确认。
4. 容器运行但后端不可达：核对容器监听地址、端口、后端路径与日志。
5. 凭据不可用：检查项目内文件和容器路径，不能通过挂载整个主目录修复。
