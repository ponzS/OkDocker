[中文](../zh/docs/APPLE-BACKEND.md)

# Apple container backend

Status: local validation of the 0.2 runtime, with later versioned-deploy behavior. Results are recorded separately. A 0.1 Docker pass is not reused.

## Decision

On 2026-11-16 the default runtime became Apple `container`. Colima, Docker, and Compose are no longer required. The UI stays native SwiftUI/AppKit. Official vminitd, VM management, and the image builder are not rewritten. The first integration uses the official CLI rather than bundling the whole runtime. Apple container still starts an independent Linux VM per container through Containerization / Virtualization.framework.

`Sources/OkDocker/AppleRuntime.swift` owns the official CLI protocol, ownership-labeled containers and networks, builds, checks, and start. `Runtime.swift` still owns the registry, directory approval, start/stop exclusion, cancellation, and port protection, and dispatches to the backend. Existing Compose code is only a compatibility and cleanup path for old registrations. A Docker context cannot impersonate the Apple backend.

- The validated runtime is `1.7.1`, tag commit `a15b46097aa4c2325da13c1fb5192b9274aab083`, Apache-2.0.
- Installer: <https://github.com/apple/container/releases/download/1.7.1/container-1.7.1-installer-signed.pkg>
- SHA256: `b6739caf3d47ca53a78f1a7edf32521420a75c7941838c3cefa75f30b80f5a97`.
- `pkgutil --check-signature` reported Apple Inc. - Containerization (`UPBK2H6LZM`), notarized by Apple. The normal system installer asks for administrator approval. Quarantine is not stripped and system authorization is not bypassed.
- Official kernel: Kata 4.3.1 ARM64, archive SHA256 `2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6`. The first official URLSession download hit a TLS close. A normal TLS curl retry was checked against the official digest before local install. No check was skipped.
- Minimum macOS 26 / Apple Silicon. Images are Linux arm64. Rosetta is not enabled silently.

## Interface and migration

The internal backend key is `apple-container`. Old records keep their context so a running instance is not changed quietly. The registry upgrade saves a backup first and moves the default backend to Apple. Login startup for old apps is paused. Old cards are marked as needing migration. Migration changes only the registration, leaves login startup off, and does not build, start, move, or delete data.

Migration requires an explicit confirmation that the old Docker instance is stopped. If the old engine is reachable, running must actually be 0. An unreachable old engine is not treated as proof that old containers have stopped. Migration is limited to the manager's registration. It does not switch an existing host deployment or take over its data. Confirm the original service is stopped before switching.

The controlled declaration remains schemaVersion 1. Extra CLI arguments, arbitrary Compose, host commands, socket or full USB mapping, and implicit SSH-agent or home sharing are not accepted. Container ports stay on 127.0.0.1. A separately authorized host LAN helper does not change container configuration or rebuild a writable layer. See CONFIGURATION.md. Before start and after build, real LISTEN is checked. After create, official inspect is audited for mounts, network, labels, and ports. Ordinary configuration changes still require a stop and a new import. A version-only change rebuilds while reusing dependency cache and switches. The new image and stopped container are prepared and audited before the old service stops. The new generation is selected atomically and then started. Old writable layers and images are kept and not deleted silently. `build.script` runs in a Linux Dockerfile stage and is not a host command hook.

Each app has its own vmnet network. Official custom networks do not provide Compose-style bare service-name discovery. Arbitrary multi-service Compose equivalence is not claimed. ADB does not depend on custom-network DNS or a dynamic IP. Listening on the vmnet gateway was abandoned because that gateway is not a bindable Mac interface. A new deployment mounts the Mac's private token socket into the approved backend container. A relay in that same container injects the token and serves a local Unix socket to the app. There is no TCP bridge listen and no PF / DNS / Private Relay change. The socket path is under a mode 0700 directory in the current user's temporary directory, to stay within `sockaddr_un` limits. An already created old sidecar is not rewritten in place. After a version switch succeeds, that VM is stopped. The Android switch still does not claim mandatory isolation from a malicious program.

Per-app CPU and memory plans are not required, and unlimited elasticity is not promised. The official CLI still has a VM start capacity and default limit (1.7.1 defaults to 4 vCPU / 1 GiB). That is not a fixed host reservation. Memory freed by the guest may not return to the Mac. Older measurements are kept. This is not claimed to be lighter than Colima in every case.

## Lifecycle and validation bar

- State comes from real `container list --all --format json`. HTTP and mounted I/O are checked separately.
- Containers belong to an app by app ID plus support-directory digest. Networks are label-checked the same way. `--all` is not used to delete or stop resources. Observation and logs use the selected deployment. Stop and remove cover every generation of that app. Application version and deployment id are labels.
- Force stop sends KILL, waits until create and start clients are cancelled, and checks again. It does not delete container writable layers or host data, and it does not stop the shared runtime or ADB server.
- Quitting the UI does not stop services. Reopening restores from actual state. Login items are off by default.
- Independent examples cover import, real Linux arm64, mounts and ports, SIGKILL, host and container writable-layer persistence, two apps not affecting each other, explicit migration of an old record, configuration changes, hostile environment and arguments, a busy port, start cancellation and orphan clients, and a real GUI cold start with file and HTTP I/O.

The pass and fail scope is recorded separately in `VALIDATION.md`. Old Docker reports are historical evidence, not Apple backend validation.
