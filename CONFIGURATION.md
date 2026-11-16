[中文](zh/CONFIGURATION.md)

# OkDocker application rules (schemaVersion 1)

Put **`okdocker.json` in the application folder root**. In OkDocker, click Add app, choose that directory or this file, confirm the approval, and import. Click the icon to start. Right-click to manage. Import itself does not build or start. Import only code you trust.

## Minimal example

```json
{
  "schemaVersion": 1,
  "version": "1.0.0",
  "id": "my-service",
  "name": "My service",
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

Create the `public/`, `server/`, and `Dockerfile` paths the example names, plus an optional icon. Delete `icon` if you have none; the UI shows a default. `examples/hello/` can be imported as-is.

The default backend is **Apple container 1.7.1 (macOS 26+ / Apple Silicon)**. This file is not Compose and does not accept arbitrary CLI arguments. A legacy Docker registration must be migrated explicitly. Switching the default backend does not move application data.

## Fields and paths

| Field | Rule |
|---|---|
| `schemaVersion` | Configuration format version. Must be `1`. This is not the application version |
| `version` | Application version string, suggested form `1.0.0`. 1–64 characters, starting with a letter or digit; the rest may be letters, digits, or `. _ + -`. Compared on every start. A change rebuilds and deploys. Old configs may omit it |
| `id` | Starts with a lowercase letter, then lowercase letters, digits, or hyphens, at most 48 characters |
| `name` | Display name, 1–60 characters |
| `icon` | Optional PNG/JPG/ICNS under 8 MiB, relative to this directory. It cannot point outside |
| `frontend` | Frontend URL the Mac browser opens. Required |
| `backend` | Backend URL or health probe the Mac can reach. Required |
| `*.service` | A name in `services`. Frontend and backend may be the same service |
| `*.directory` | Where that code lives inside the application directory. It must exist. This is a source check, not a script to run |
| `*.path` | HTTP URL path, such as `/` or `/health`. Not a host disk path |
| `*.hostPort` | Mac port, 1024–65535. The container is always published only on `127.0.0.1`. LAN access is a separate user grant |
| `*.containerPort` | TCP port the service listens on inside the container, 1–65535 |
| `autoStart` | Default `false`. Import always leaves login startup off. The file cannot register a login item by itself |
| `hostAndroidDevices` | Default `false`. `true` opens ADB to **every already authorized Android device, including ones connected later**. It is not passthrough of every Mac device |
| `services` | 1–16 services. Names use lowercase letters, digits, and hyphens. `okdocker-adb` is reserved |

A shared port must use the same service and the same host/container port, with different paths. Separate frontend and backend services name their own services and ports. Listen on `0.0.0.0` inside the container, not `127.0.0.1`. LAN is off by default. A directory field is not an extra automatic mount.

## Allow LAN access (manager setting, not a file permission)

Turn on **Allow LAN access** from the app's context menu or App settings. It is off by default. An imported config cannot turn it on. Do not add `lanAccess`, `host`, or a bind address to the JSON. The setting is stored in the manager's private registry for the imported app. It does not change the configuration digest or rebuild the container.

- The container still listens on Mac `127.0.0.1:hostPort`. A separate native TCP helper forwards this app's **frontend and backend ports** to the Mac's current Wi-Fi/Ethernet (`en*`) private IPv4 address (10/8, 172.16/12, 192.168/16). It does not bind `0.0.0.0`, the public internet, VPN, a virtual interface, or IPv6, and it does not publish ADB. It is not a firewall or an identity system.
- App settings show the Mac addresses that are actually listening. You can open or copy them. **Copy LAN address** copies every ready frontend address. Do not replace that address with a VM IP seen inside the container. Frontends should use a relative API path or a configurable backend address, not a hard-coded `127.0.0.1` for a remote browser.
- Devices on the same network can reach the published application interfaces. Authentication, accounts, and access control belong to the app. Enable this only on a trusted network. Approve the normal macOS Local Network / firewall prompt. The manager does not change the firewall or TCC, and it does not map router ports. This currently applies to the Apple backend.
- The switch does not restart or rebuild a running container. Turning it off disconnects forwarded connections. The local endpoint stays. Stopping the app stops its own LAN helper. Quitting the manager UI keeps an already authorized gateway. The next app start or manager launch restores an authorized gateway. A stopped app keeps the permission but does not start the service.
- Addresses rebind when the network changes. Each new connection checks the original loopback publisher and port identity, so a reused local port is not forwarded. If no private address is available, or a port conflicts, the failure is shown as-is. The listen scope is not widened.

CLI: `OkDocker --cli lan <ID> on|off|status`. `on` explicitly allows the frontend and backend to be reached on the same network. It does not add a password for the app.

## Service configuration

- Choose exactly one of `image` or `build`. Pin an image digest when distributing. `build.context` is relative to the application root. `build.dockerfile` and optional `build.script` are relative to the context. They must not escape through `..` or a symlink. See below for where `build.script` runs and how the Dockerfile marker works.
- `command` is optional. It is an array of a program and arguments **inside the container**, not a Mac shell command. If omitted, the image entrypoint is used. Compiled apps must be rebuilt after code changes. Hot reload is not promised for every language.
- `environment` is optional string pairs. Keep credentials in mode `0600` files inside the directory and ignore them in Git. Do not put them in the config or the image. `$` is passed literally and does not expand Mac environment variables.
- `workingDirectory` is an absolute path inside the container.
- The Apple backend currently requires `source` to be a directory. A single-file mount is not silently widened to its parent. Paths containing a comma or newline cannot be passed unambiguously and are rejected; rename them. The internal ADB socket is a fixed exception after an explicit grant. The config cannot name an arbitrary socket.
- `mounts` defaults to `[{"source":".","target":"/workspace","readOnly":false}]`. `source` is relative to the application root. `readOnly: true` is read-only. An empty array `[]` mounts no host directory. Create directories first. Out-of-scope paths, special sockets, and system device targets are rejected.
- Each app gets an ownership-labeled vmnet network. Each container is its own lightweight VM. For persistent data, create `data/` inside the application directory and map it explicitly. A resource plan is not required. The official default VM capacity (4 vCPU / 1 GiB) still exists and is not a host reservation. Idle guest memory may not return to the Mac. Default NAT is not an outbound firewall against the Mac or the LAN.
- There is no Compose-style bare service-name discovery. Do not assume `backend:8080` resolves inside the container. ADB uses a stable Unix socket and does not depend on a changing VM IP.
- Use this controlled declaration. The manager builds the argument array and, before start, audits the real `container inspect` mounts, network, and ports. **It does not run arbitrary host start/stop scripts, import arbitrary Compose YAML, or allow privileged mode, the Docker socket, external networks, host PID/network, or full USB device mapping.** That is what keeps "only this directory" from being bypassed by config.
- **Changing only `version` does not require a new import** and can deploy automatically. Every other change, including script path, directories, ports, command, environment, mounts, and Android permission, must be stopped and imported again, then deployed with a new version. If the same version does not match the existing container, reuse is refused and the layer is not deleted silently. Moving the directory still requires a new import.
- Source or script content changes are not detected automatically. To package new code, also change `version`. Same-version stop/start reuses the container and image. It is not hot reload.

## Custom build script

`build.script` is an optional **Linux build script path, relative to `build.context`**. A standard Linux shebang is supported (`#!/bin/sh`, `#!/usr/bin/env bash`, or `#!/usr/bin/env python3`). Without a shebang, `/bin/sh` is used. The interpreter must already be in the build image. Apple backend only. The script runs in a **Linux build stage** of the Dockerfile, not on the Mac. It does not get extra host mounts and does not inherit the runtime `environment` / `mounts`. Do not point it at a host packaging script that needs Xcode, `osascript`, or Mac CLIs.

```json
"build": {
  "context": ".",
  "dockerfile": "Dockerfile",
  "script": "scripts/build.sh"
}
```

Prepare the toolchain and copy sources in the Dockerfile. Place **one independent line**, `# okdocker:build-script`, in the stage that should run the script:

```dockerfile
# Replace the placeholder base images with the Linux arm64 images this project actually needs. Pin digests when distributing.
FROM your-build-image AS build
WORKDIR /src
COPY . .
# okdocker:build-script

FROM your-runtime-image
COPY --from=build /src/dist /app
WORKDIR /app
CMD ["/app/my-server"]
```

The manager writes a temporary Dockerfile and replaces the marker with a JSON exec `RUN` (`RUN ["/bin/sh", "./scripts/build.sh"]` when there is no shebang, or the declared Linux interpreter). It does not edit the original file or join a host shell. `WORKDIR` at that point must be the copied build-context root. The script must already have been `COPY`ed in, and the interpreter and compilers must be available in that stage. The manager invokes the interpreter explicitly. The script does not need an executable bit on the Mac. Do not put the marker in a continued line or a heredoc, and do not also hand-write `RUN sh scripts/build.sh`. The script may call Cargo, npm, Python, or other tools the project needs. A non-zero exit fails the build. The final image and entrypoint still come from the Dockerfile. The manager does not guess where the artifact is. The marked stage must be the final stage, or the final stage must actually reference it with `COPY --from` or similar. Otherwise upstream BuildKit can skip an unused stage.

For example, `scripts/build.sh`:

```sh
#!/bin/sh
set -eu
npm ci
npm run build
```

Omit `script` when you do not need one and keep using Dockerfile `RUN` instructions. Use `.dockerignore` or `Dockerfile.dockerignore` to exclude credentials, databases, and non-source material. A generated temporary Dockerfile keeps the original Dockerfile-specific ignore rules. [`examples/scripted-web`](examples/scripted-web) is a working example.

## Version check and redeploy

1. The first start builds `build` services, including a declared script, or pulls `image` services. Later starts of the same version reuse the existing container and keep its unmounted writable layer.
2. After updating source or script content, change `version`, for example from `1.0.0` to `1.0.1`. Click start, or right-click **Start / check for update** on a running app. The CLI uses `start ID`. An authorized login start performs the same check. Opening the page does not upgrade, and source is not polled in the background.
3. When the version differs, every `build` service gets a new deployment id, a new image tag, and `--no-cache --pull`. It is packaged again from the current build context and runs the script. The old application container is not reused. An `image` service can only be pulled again and placed in a new container. A pinned digest does not change because the version string changed. Compile from source with `build`. The in-container ADB relay starts with the new backend container and is not a project source image. An old sidecar, if one still exists, is stopped after the new deployment starts. It is not deleted automatically.
4. Build, create, and audit the real configuration first. A failed build leaves the old service running. The switch removes the old LAN gateway, sends SIGTERM to the old application services, waits up to 30 seconds for the upstream force stop, then selects and starts the new deployment. That is a short outage and should be started at a suitable time. A previously authorized LAN gateway is restored. No new permission is granted automatically.
5. **Old containers, images, and writable layers are stopped and kept. They are not deleted automatically, and their unmounted data is not copied into the new container.** Persist data inside the application directory, such as `data/`. Back up before upgrading and plan database migrations. A kept layer is not a snapshot of host data. A failed switch does not automatically roll back the program or restore data, which avoids a reverse migration corrupting it. A container interrupted during preparation stays stopped. If the new deployment was already selected, the next same-version start can continue it.
6. `OkDocker --cli deployments ID` lists each deployment's version, container ID, state, and whether it is selected. It does not print environment credentials. Historical containers use disk. Removing the registration deletes that app's stopped containers and unmounted writable layers from **every generation**. The host directory stays. Restoring a historical layer requires a backup, a stopped current deployment, and a check that mounts and dependencies still work. Do not run two generations that share a persistent directory at the same time.

Versions are compared as strings, not ordered as SemVer. A downgrade or deleting an existing version is a change. `schemaVersion` remains `1`. Configs without `version` keep the old reuse behavior. The manager first saves a private `registry-before-versions.json` backup. An old registration gets an approval baseline, excluding version, when the original digest still matches. If the configuration changed before the manager upgrade and it cannot be shown that only the version changed, stop and import again once. Changing the version cannot bypass approval of other settings.

## Stop, quit, and login startup

- **Force stop** sends **SIGKILL** to every container in the app. If an old phone-bridge container is still present, it is stopped too. The manager checks that they actually stopped. **This interrupts tasks and writes and can corrupt data.** It does not delete application files or data, stop other projects, or shut down the shared ADB server.
- Closing the main window keeps the menu bar. Quitting OkDocker does not stop containers. Stopping a service requires an explicit force stop. The next launch observes containers again and does not treat an old record as truth.
- Login startup is off by default. The first time it is enabled, OkDocker registers a system login item. macOS may ask for approval. Without approval, the app switch is not reported as on.
- Login startup means "after logging into the Mac, start the service when the runtime is ready." It is not a daemon before FileVault unlock. The Apple runtime can be started from the GUI and is checked against real mounted files and page content. The first run needs the official tool and kernel, and a normal system approval. The old Colima cold-start failure path is not reused.
- There is no runtime restart policy. Only OkDocker / `SMAppService` has an explicit start policy. A crash is shown as a crash. It is not silently restarted forever.

## Android access

The image must include a Linux ADB client. The Mac must have a working ADB. When the Apple backend is enabled, OkDocker runs its own static relay inside the approved backend container instead of starting another virtual machine for the phone bridge. The Mac helper still listens on a private Unix socket in the current user's temporary directory, checks a token, rejects `host:kill`, and then connects to `127.0.0.1:5037`. The relay writes the token and accepts the app's own Linux ADB client on `/run/okdocker-adb.sock` in the same container. The app keeps using `ADB_SERVER_SOCKET=localfilesystem:/run/okdocker-adb.sock`. Application code does not need to change. There is no TCP listen for the phone bridge, no PF/DNS change, no `~/.android` mount, and no USB ownership transfer.

A new container receives the read-only token directory, the relay, and the host socket. A container created by an older release with a separate sidecar is not rewritten in place. Starting that same version keeps the old layout. The next versioned deployment creates a container with the in-container relay and, after it starts, stops the sidecar VM that is no longer needed. That writable layer is not deleted automatically. The legacy Docker/Compose path still uses a separate service inside one shared virtual machine.

**Security limit: this switch controls whether the shared ADB channel is injected. It is not a mandatory device permission against a malicious container.** Historical Colima networking was shown to reach Mac ADB directly. That is not a pass or fail result for the Apple network. The new backend does not publish an ADB TCP channel, but it has not completed every malicious outbound or host-port bypass check. The token protects this bridge only. It does not authenticate other Mac ports. This release still supports trusted applications only. Turning the switch off is not a mandatory device sandbox. A directory mount limit is not a network limit.

The phone still needs USB debugging, a normal trust prompt, and the install and input permissions the app needs. Other Mac ADB tools can usually keep working, but simultaneous clicks, input, or instrumentation interfere with each other. The bridge rejects an initial `host:kill`. Stopping the app does not call the shared ADB shutdown. Client and server versions must be compatible. This switch is not permission for every Mac device or directory, and it does not bypass the phone's own authorization. Only backends, hardware, and read-only operations listed in `docs/VALIDATION.md` count as passed. Other runtimes and phone capabilities need their own validation.

## Troubleshooting

0. Desktop, Downloads, and external disks: macOS may ask for access the first time. Choose the directory in the import panel and approve it normally. TCC is not disabled, and system permission is not granted automatically.
1. "Engine not ready": install official Apple container 1.7.1 and click Start runtime. If the first kernel download fails, retry with signature, TLS, and digest checks still on. For an old card, confirm the old instance is stopped, then migrate the registration. Do not create a Docker context and pretend the Apple migration is done.
2. "Port in use": change `hostPort` and import again. The program occupying the port is not killed.
3. "Configuration changed": a version-only change with an existing approval baseline can start directly. Any other change, or a missing baseline, must be stopped and imported again.
4. The container is running but the backend is unreachable: check the listen address, port, backend path, and logs. If a build script fails, check the Linux toolchain, `COPY` / `WORKDIR`, the marker location, and the error output. If the code changed but the version did not, change `version` too.
5. Credentials are unavailable: check the file inside the project and the container path. Do not fix this by mounting the whole home directory.
