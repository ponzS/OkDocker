[中文](../zh/docs/VALIDATION.md)

# Local validation notes · Apple container

These notes cover OkDocker itself. They use isolated fixtures, ports, and private registries. They do not deploy or mount a production directory.

## 0.3 application versions and build scripts (2026-11-16)

Environment: Apple M4 / 16 GiB / macOS 27.2 / Apple container 1.7.1, official per-container Linux arm64 VMs.

- **71 Swift tests passed** (51 plus 20): application `version` separated from `schemaVersion`, version-string and old-registry compatibility, full approval digest with version excluded, actual container version comparison, generation name length and uniqueness, script path and symlink limits, JSON exec arguments, Linux shebang and default `sh`, a single build-stage marker, original Dockerfile unchanged, Dockerfile-specific ignore kept, and temporary file cleanup. `artifacts/version-swift-test.log`.
- **31 real version/script checks passed:** two apps; shell and Python shebangs packaged on real Linux and returned build output; the Dockerfile and host did not execute the script themselves; same-version run/stop/restart reused the container; a version change produced a new image reference and container; a version-only change still produced a new UUID artifact (`okdocker.json` is excluded from the build context, confirming an uncached `RUN`); a downgrade also rebuilt; the old layer stayed stopped and could be read after the current service stopped; the new container did not inherit the old layer; the host mount remained; a partly stopped selected generation could continue; a failing script or a version change during a build did not stop the old service; version could not bypass port approval; an authorized LAN helper followed the new publisher; the ADB Unix channel still worked; ordinary and Dockerfile-specific `.dockerignore` both applied; an old registration received an approval baseline safely; stop and remove covered every generation and did not change another container's observed state. `artifacts/version-validation/report.json`, `artifacts/version-integration-test.log`. Cleanup errors were empty.
- **Core 30 / cancellation 7 regressions passed:** `artifacts/version-core-regression.log`, `artifacts/version-cancellation-regression.log`. Cancellation still uses a real build plugin, an orphan client, and a delayed check. It does not stop the shared runtime or builder.
- **0.3.0 was installed to `/Applications/OkDocker.app` and retested:** the old 0.2.1 bundle was backed up first. The signature matched the built executable. The signature is ad-hoc, not Developer ID notarization. The installed program reran version/script **31**, core **30**, and cancellation **7**. Native install checks **12**: real main window, menu bar, close and reopen, rules and versioned app settings, the script example started from the GUI, a GUI start while the old service was running checked the new version and actually switched HTTP content, quitting the UI kept the service, rules matched the source, and existing app registrations and the global login preference were unchanged. Login startup was tested only with an isolated registry policy. `SMAppService` was not changed. `tests/installed_smoke.py`, `artifacts/version-installed/report.json`, and `version-installed-{core,cancellation,versions}.log`.
- That round did not restart a user's existing app or change its source directory or configuration. It did not do a full GUI click-through, a real logout, phone LAN, performance, or database upgrade/rollback validation. Settings text that was truncated was changed to wrap and rechecked. Screenshots are only the fixture's own views.

That ADB round sent only `host:version`. It did not enumerate or operate phones. LAN requests were from the Mac to its own private address and **do not replace the failed physical-phone network result below**. A kept layer is not a snapshot of mounted data. Automatic data migration, automatic rollback, and power-loss transactions are not claimed. Staging rules were updated, but a neighboring real application was not generated, installed, or given a changed production configuration.

Recheck:

```sh
swift test
bash scripts/build-app.sh
python3 tests/apple_versions.py
OKDOCKER_BIN="$PWD/dist/OkDocker.app/Contents/MacOS/OkDocker" python3 tests/apple_integration.py
python3 tests/apple_cancellation.py
# Installed copy: do not stop the shared runtime or change system login items
python3 tests/installed_smoke.py
OKDOCKER_BIN=/Applications/OkDocker.app/Contents/MacOS/OkDocker python3 tests/apple_versions.py
```

## 0.2.1 LAN access and copying rules (2026-11-16)

- The generic manager UI and CONFIGURATION do not contain a specific product's name or action prompts. They keep generic notes about writes, authentication, permissions, and lifecycle.
- **51 Swift tests passed:** the previous 40, plus LAN private-address and physical-interface filtering, old records defaulting off, permission encoding, a manifest that cannot grant LAN access, URLs, complete generic AI rules, and a verbatim copy onto a private `NSPasteboard` that does not replace the user's clipboard. `artifacts/lan-swift-test.log`.
- **26 real LAN checks passed:** two isolated apps, off by default, an explicit switch, the Mac address that is actually listening, separate frontend and backend ports, the local endpoint unchanged, inspect configuration and guest boot ID unchanged, another app not published, a full 1 MiB upload and download, bidirectional HTTP Upgrade data, removal while running rejected without disturbing the gateway, existing connections disconnected, a missing ready file still able to revoke the helper, the gateway kept after quitting the GUI, force stop and restart, a configuration change still revocable, and a reused local port not forwarded. `artifacts/lan-validation/report.json`.
- **Native UI:** the rules window and LAN settings window loaded and only their own views were captured. Rules include the copy-for-AI button and explanation. Settings show the Mac address that is listening and a copy button. Test images are under the report `work/ui`. The user's desktop and phone screens were not captured.
- **Core 30 / cancellation 7 regressions passed:** `artifacts/lan-core-regression.log`, `artifacts/lan-cancellation-regression.log`.

### Not passed: physical phone network

Requests from this Mac to its own LAN address passed. **LAN HTTP from 6 authorized phones did not succeed**, so phone-side validation is not claimed. The Mac observed `192.168.10.124` and `192.168.31.159`. Most phones were on the 31 network, with another cellular path. A temporary Python HTTP listener independent of OkDocker, returning only fixed test text and removed afterward, also saw `nc: connect: No route to host` from a phone. The basic phone-to-Mac path was not established. Wireless client isolation, routing, or another network limit was not isolated.

Only the system firewall state was read (disabled at the time). **The firewall, TCC, routes, phone Wi-Fi, and system authorization were not changed.** Validation has to continue on a network a real client can reach. A Mac connecting to its own LAN IP is not a physical LAN client. No business API of a user app was called, and no user VM or file was rebuilt or modified.

### Implementation note

`NWListener` returned `EADDRINUSE` when it shared a port with the official loopback publisher. A POSIX bind/listen on that same specific address and port worked, so the LAN helper uses a POSIX socket and bounded `poll` forwarding in both directions. Official container publish arguments are not changed. Each helper allows at most 64 connections and 64 KiB of buffer in each direction. Throughput, latency, and lower memory use are not performance claims. Only private `en*` IPv4 is supported. IPv6, VPN, and the public internet are not.

Recheck: `swift test`, `bash scripts/build-app.sh`, `python3 tests/lan_integration.py`. If a real phone is not on a reachable network, the report keeps `realPhoneLANReadOnlyHTTP: false` and does not fake a pass.

## 0.2 conclusion (2026-11-16)

The default wiring is official Apple **container 1.7.1**, not a Colima/Docker context alias. macOS 27.2 / Apple M4 / arm64 / 16 GiB, native UI and the official runtime. The conclusions below come from isolated directories, real Linux VMs, files, HTTP, and read-only phone operations. They are not simulated values. This remains a local validation build. It does not represent every piece of hardware, every network permission, or a real external action.

### Passed

- **Swift, 40:** the original 17 configuration, path, and port protections, plus Apple arguments, ownership, unknown state fail-closed, and audits of actual mounts, network, ports, sockets, platform, runtime, and capabilities. `artifacts/apple-swift-test.log`.
- **Apple core, 30:** two real apps, arm64, only approved mounts, loopback ports, literal environment and a hostile `.env`, Android off injecting no channel, a private network, KILL after ignored TERM, another app still alive, host and container writable layers kept across restart, a configuration change refusing a silent layer delete, a wildcard port occupancy blocked before start, old registry backup, and explicit registration migration. `artifacts/apple-validation/report.json`.
- **Cancellation, 7:** a real pending build, a normal launcher, and an orphan build-plugin client after its parent was killed, revoked by project and support-directory digest. A 48-second wait did not see a late start. The shared builder was not stopped. The official CLI execs into the build plugin. Matching only the original CLI name missed orphans; that is fixed. `artifacts/apple-cancellation/report.json`.
- **ADB, 11:** the official Unix socket `.into` / `.outOf` chain used by that release, a private directory and mode 0600 socket, a wrong token rejected, shared ADB shutdown rejected, real device enumeration and read-only `getprop`, stop not touching the shared service, and restart not deleting the backend writable layer while restoring the channel. **2 authorized phones online** in that round. The older count of 7 is not reused. `artifacts/apple-android/report.json`. Current new deployments no longer use that separate sidecar VM. See CONFIGURATION.md.
- **Native UI and a real cold runtime:** `SMAppService` register/unregister restored the original off preference. When the shared runtime had no other work, the service was stopped normally, the GUI started the official runtime, an isolated fixture autostarted, and the mounted page content was read. Main window, menu bar, close and reopen, only own views captured, and the page still reachable after quitting the UI. Test resources were removed at the end. The Mac account was not logged out. `artifacts/apple-ui/report.json`.

### Limits and troubleshooting

1. The first official kernel download was interrupted by TLS. The same official archive was downloaded again with normal TLS and checked with both the official SHA256 and `container system kernel set --digest`. Signature, TLS, and digest checks were not disabled. The signed installer is notarized by Apple. That does not mean OkDocker itself has a Developer ID distribution notarization.
2. The vmnet gateway is not a directly bindable Mac interface. A LAN listen on it was not used. The 0.2 ADB path used a separate sidecar and an official Unix socket. Current new deployments relay inside the approved backend container and do not start a separate VM for the phone bridge. The host token directory stays read-only. The independent-VM helper in the 0.2 notes describes that release, not the layout of a newly created container.
3. The Android switch does not promise strong isolation against malicious outbound traffic. Official custom networks have no Compose-style bare service-name discovery. A single-file mount is not widened to the parent directory. Image source changes need an explicit backup and rebuild. Layers are not deleted silently and source is not hot-updated.
4. Each official VM defaults to 4 vCPU / 1 GiB. The builder defaults to 2 vCPU / 2 GiB. That is not a fixed host reservation and not unlimited elasticity. Multi-load memory-return performance was not validated. This is not promised to use less memory than Colima. The official builder's own privileged guest and Rosetta support are upstream behavior. Product workloads are arm64, Rosetta is off, and applications cannot customize those permissions.

### 0.2 recheck

```sh
bash scripts/build-app.sh
swift test
OKDOCKER_BIN="$PWD/dist/OkDocker.app/Contents/MacOS/OkDocker" python3 tests/apple_integration.py
python3 tests/apple_cancellation.py
python3 tests/apple_android.py
# A GUI cold-start test must first confirm there is no other Apple container or build task. The script refuses to stop other work.
python3 tests/apple_ui_smoke.py
```

Test source and reports are in this project. Runtime fixtures live under this app's Application Support `Validation/Apple*/`. A native production service is not a test fixture. Historical Docker scripts and reports are regression references only, not Apple results.

## History: 0.1 Docker/Colima validation (not the current default backend)

**A native app and an already ready Docker runtime can import, start, serve a page, report real state, SIGKILL, keep data, and use shared ADB. That is not a claim that everything is delivered.**

Two items explicitly did not pass:

1. **Mandatory Android permission isolation is not implemented.** Colima's default network lets a container connect to Mac loopback ADB 5037 by itself. `hostAndroidDevices` only decides whether a shared channel is provided. It does not stop malicious code from bypassing that channel. Token checks and rejection of an initial `host:kill` passed. That is not proof the raw ADB bypass is blocked. Trusted apps only.
2. **GUI cold start of Colima file sharing does not pass and that path is disabled.** A VM and container were observed Running, then shared-directory stat, container create, and guest SSH I/O blocked. A normal stop also blocked. Running is not frontend or filesystem availability. Only the VZ hostagent for the `okdocker` test profile was force-stopped, and a runtime started normally from the terminal was restored. The full regression passed after that. The root cause was not isolated. It is not asserted to be TCC, and system permission was not disabled or approved automatically. The Colima button now only shows start instructions. Login policy waits for an externally ready runtime.

### Environment

- Apple M4, 10 CPU cores, 16 GiB RAM, arm64.
- macOS 27.2 (26B123), Xcode 27.2, Swift 6.4.2. The package's minimum deployment was macOS 15, Swift 5 language mode.
- Homebrew: Colima 0.10.3, Lima 2.3.0, Docker CLI 29.9.3, Compose 5.7.1. Local Docker server 29.5.2.
- Isolated profile/context: `okdocker` / `colima-okdocker`, VZ + virtiofs. The shared VM capacity was 4 vCPU / 6 GiB / 80 GiB virtual disk. That is not a per-app quota or a measured host occupancy number.
- Rust, Debian, and Python base images used pinned digests. Cargo used the working tree's `Cargo.lock` with `--locked`. Four top-level Debian packages were pinned. The full dpkg list stays in the image at `/usr/share/okdocker/package-versions.txt`. Not every Debian transitive dependency is claimed to be permanently reproducible from the current mirror.

Passes come from real local processes, Docker inspect, HTTP, disk files, or authorized phones. They are not simulated return values. Force stop was verified with a container that ignored SIGTERM, exit code 137, and actual running=0. Eight seconds is a test timeout, not a performance baseline.

### Latest full regression

**Swift, 17.** `swift test`: valid configuration, directory and symlink escape, privileged fields, unknown nested permissions, an external Dockerfile, port conflicts, endpoint references, URL limits, Compose `$` literals, and host wildcard/loopback LISTEN occupancy. Evidence: `artifacts/swift-test.log`.

**Real Docker lifecycle, 28.** `python3 tests/integration.py`:

- Two independent apps actually started. A config that tried to enable login startup still defaulted off.
- Mounts pointed only at each app's directory. A sibling marker and the Docker socket were not visible. Ports bound only to `127.0.0.1`.
- ADB was not injected by default and was not expanded into mandatory device isolation.
- `${SECRET}` and `$` in the environment did not expand the Mac environment. A directory `.env` could not change the project or Compose source.
- A written file survived SIGKILL, exit code 137, an actual stop, and a restart. Another project stayed reachable.
- A permission change required a new import. An old instance could still be force-stopped after the configuration changed.
- An in-progress build was cancelled. After the launcher parent was killed, an explicit stop still revoked only that project's orphan Compose client, and it did not start later.
- A macOS `0.0.0.0` wildcard listener caused start to be refused before any application container was created.

Evidence: `artifacts/validation/report.json`, `artifacts/integration-test.log`.

**Native window and login policy.** `python3 tests/ui_smoke.py`:

- A real `NSWindow` was visible, the menu bar existed, closing the window kept the menu bar, and the window reopened.
- The capture is this app's own view, not the user's desktop or another app.
- `SMAppService` registered from off to enabled and unregistered back to off. The app login-startup switch persisted.
- **The runtime was already started normally from the terminal.** Restarting the UI started the fixture according to login policy. After quitting the UI, the container and real page content were still reachable.
- Cleanup turned off login startup and the system login item. Both registered apps ended with login startup off.

The Mac account was not logged out. This is not a pre-FileVault boot-service validation. Context-menu actions exist, but this is not a complete AX/XCUITest click-through. System permission prompts and other macOS, hardware, and runtime combinations were not all tested.

Evidence: `artifacts/ui/native-ui.json`, `artifacts/ui-smoke-test.log`, `artifacts/login-self-test.log`.

### Risk regression

Darwin `SO_REUSEADDR` can let a specific-address bind succeed beside a wildcard listener, so a successful bind alone is not an occupancy test. The fix checks the real LISTEN socket, checks again after image build or pull, and creates the app with `--no-build --pull never`.

Start cancellation no longer depends only on a living parent. Stop revokes the Compose client that matches the unique project and private compose path. Lock file descriptors use `CLOEXEC`. The Docker daemon, shared ADB, and other projects are not killed.

### Recheck

Start the runtime normally as the README describes and confirm the host directory is usable. Do not enable the disabled GUI cold-start path:

```sh
bash scripts/build-app.sh
swift test
python3 tests/integration.py
# Close an existing OkDocker UI first. The script protects the existing login preference and restores its own changes.
python3 tests/ui_smoke.py
```

Runtime fixtures live under this app's Application Support `Validation/` and contain only explicitly staged test code and new data. Do not grant the whole home directory or disable package signatures, TLS, file digests, or TCC in order to test.
