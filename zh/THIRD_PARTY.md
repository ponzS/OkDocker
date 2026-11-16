[English](../THIRD_PARTY.md)

# 来源与许可证

OkDocker 自有代码 MIT；SwiftUI/AppKit/Network/ServiceManagement 使用系统框架，没有复制第三方 UI 或 Docker 图标。应用图标由本项目 AppKit 绘图脚本生成。

**0.2 默认运行时不打包进 app：Apple `container` 1.7.1**（Apache-2.0，tag commit `a15b46097aa4c2325da13c1fb5192b9274aab083`），底层官方 `Containerization` 0.54.0（Apache-2.0）。通过 Apple 官方签名且公证的安装器正常安装。来源、SHA256 与验收见 `docs/APPLE-BACKEND.md`。Linux 内核采用官方默认 Kata Containers 4.3.1 ARM64 分发，Linux GPL-2.0 等许可证仍适用；来源 <https://github.com/kata-containers/kata-containers/releases/tag/4.3.1>，下载归档保持官方 SHA256 校验。官方 vminit/builder 镜像使用运行时随附版本与摘要，实际解析结果见验证产物；不将 tag 等同全传递依赖的永久字节复现。


手机桥的容器内转发程序是本仓库的静态 Go 二进制，随 OkDocker 以 MIT 分发。旧 Docker 兼容路径仍可使用 Resources/Android 的 Python/Alpine 客户端镜像，固定摘要见该 Dockerfile。

历史/兼容后端不打包进 app：Docker CLI 29.9.3（Apache-2.0）、Docker Compose 5.7.1（Apache-2.0）、Colima 0.10.3（MIT）、Lima 2.3.0（Apache-2.0），本机通过 Homebrew 安装；以实际上游发行文件为准。不要将这些版本等同每一台引擎的 server 版本。


验证镜像的 Debian 四项顶层包版本固定在集成 Dockerfile，完整传递包版本记录在镜像 `/usr/share/okdocker/package-versions.txt`；当前不是永久 Debian snapshot 仓库锁定，不声称未来任意时间字节级重建。缺失历史包时应失败并重新审核升级，不能关闭签名或校验。

