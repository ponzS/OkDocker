[中文](zh/THIRD_PARTY.md)

# Sources and licenses

OkDocker's own code is MIT. SwiftUI, AppKit, Network, and ServiceManagement are system frameworks. No third-party UI or Docker icon is copied. The app icon is drawn by this project's AppKit script.

The in-container Android relay is a static Go binary in this repository, distributed with OkDocker under MIT. The legacy Docker path can still use the Python/Alpine client image in `Resources/Android`; its pinned digest is in that Dockerfile.

**The 0.2 default runtime is not bundled in the app: Apple `container` 1.7.1** (Apache-2.0, tag commit `a15b46097aa4c2325da13c1fb5192b9274aab083`), on official `Containerization` 0.54.0 (Apache-2.0). Install it with Apple's signed and notarized installer. Source, SHA256, and validation are in `docs/APPLE-BACKEND.md`. The Linux kernel is the official default Kata Containers 4.3.1 ARM64 distribution. Linux GPL-2.0 and the other package licenses still apply. Source: <https://github.com/kata-containers/kata-containers/releases/tag/4.3.1>. The downloaded archive keeps the official SHA256 check. Official vminit/builder images use the versions and digests shipped with the runtime. A tag is not a permanent byte-for-byte reproduction of every transitive dependency.

Legacy/compatible backends are not bundled: Docker CLI 29.9.3 (Apache-2.0), Docker Compose 5.7.1 (Apache-2.0), Colima 0.10.3 (MIT), and Lima 2.3.0 (Apache-2.0), installed locally with Homebrew. Use the actual upstream release files. Do not treat these versions as every engine's server version.

Validation images pin the top-level Debian package versions in the integration Dockerfile. The full transitive package list is recorded in the image at `/usr/share/okdocker/package-versions.txt`. This is not a permanent Debian snapshot lock and does not claim a future byte-for-byte rebuild. If a historical package is missing, fail and review the upgrade. Do not disable signatures or checksums.
