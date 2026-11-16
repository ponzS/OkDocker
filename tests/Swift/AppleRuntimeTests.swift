import XCTest
@testable import OkDocker

final class AppleRuntimeTests: XCTestCase {
    func fixture(environment: [String: String] = [:], mounts: [[String: Any]]? = nil) throws -> (Validated, AppRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var service: [String: Any] = ["image": "example/app:1", "environment": environment, "command": ["echo", "${HOME}", "a$b"]]
        if let mounts { service["mounts"] = mounts }
        let endpoint: [String: Any] = ["service": "app", "directory": ".", "path": "/", "hostPort": 19800, "containerPort": 8080]
        let object: [String: Any] = ["schemaVersion": 1, "id": "demo", "name": "Demo", "frontend": endpoint, "backend": endpoint, "services": ["app": service]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("okdocker.json"))
        let v = try validate(root: root)
        let r = AppRecord(id: "test-app-id", root: v.root.path, name: "Demo", project: "okdocker-test-app", context: AppleRuntime.context, autoStart: false, manifestHash: v.hash, importedAt: Date())
        return (v, r)
    }
    func actual(_ v: Validated, _ r: AppRecord) -> [String: Any] {
        ["configuration": ["id": AppleRuntime.name(r, "app"), "labels": AppleRuntime.labels(r).merging(["dev.okdocker.manifest": v.hash], uniquingKeysWith: { _, b in b }),
          "platform": ["architecture": "arm64", "os": "linux"], "runtimeHandler": "container-runtime-linux", "useInit": true, "capDrop": ["CAP_NET_RAW"], "mounts": [["type": ["virtiofs": [:]], "source": v.root.path, "destination": "/workspace", "options": []]],
          "networks": [["network": r.project]], "publishedPorts": [["hostAddress": "127.0.0.1", "hostPort": 19800, "containerPort": 8080, "proto": "tcp", "count": 1]]], "status": ["state": "stopped"]]
    }
    func audit(_ o: [String: Any], _ v: Validated, _ r: AppRecord) throws { try AppleRuntime.audit(o, record: r, v: v, service: "app", spec: v.manifest.services["app"]!) }
    func mutate(_ key: String, _ value: Any, _ o: [String: Any]) -> [String: Any] {
        var o = o; var c = o["configuration"] as! [String: Any]; c[key] = value; o["configuration"] = c; return o
    }
    func testDefaultBackendIsApple() { XCTAssertEqual(Registry().context, "apple-container"); XCTAssertEqual(Registry().schemaVersion, 2) }
    func testLegacyRegistryStillDecodes() throws {
        let r = try JSONDecoder().decode(Registry.self, from: Data("{\"schemaVersion\":1,\"context\":\"colima-okdocker\",\"apps\":[]}".utf8))
        XCTAssertEqual(r.schemaVersion, 1); XCTAssertEqual(r.context, "colima-okdocker")
    }
    func testArgumentsAreLiteralAndImageIsAfterSeparator() throws {
        let (v, r) = try fixture(environment: ["VALUE": "${HOME}; $(touch BAD)\nMORE=literal"])
        let args = try AppleRuntime.createArguments(r, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1")
        XCTAssertTrue(args.contains("VALUE=${HOME}; $(touch BAD)\nMORE=literal"))
        XCTAssertEqual(Array(args.suffix(5)), ["--", "example/app:1", "echo", "${HOME}", "a$b"])
        XCTAssertFalse(args.contains("--ssh")); XCTAssertFalse(args.contains("--rosetta")); XCTAssertFalse(args.contains("--virtualization"))
        XCTAssertFalse(args.contains("--memory")); XCTAssertFalse(args.contains("--cpus"))
    }
    func testSharedEndpointProducesOneLoopbackPublish() throws {
        let (v, r) = try fixture(); let args = try AppleRuntime.createArguments(r, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1")
        XCTAssertEqual(args.filter { $0 == "--publish" }.count, 1); XCTAssertTrue(args.contains("127.0.0.1:19800:8080/tcp"))
    }
    func testCommaMountCannotInjectOptions() { XCTAssertThrowsError(try AppleRuntime.mountArgument(source: "/safe,path=/Users", target: "/workspace", readOnly: false)) }
    func testReadonlyMountArgument() throws { XCTAssertEqual(try AppleRuntime.mountArgument(source: "/safe path", target: "/workspace", readOnly: true), "type=bind,source=/safe path,target=/workspace,readonly") }
    func testNulEnvironmentRejected() throws {
        let (v, r) = try fixture(environment: ["VALUE": "a\0b"])
        XCTAssertThrowsError(try AppleRuntime.createArguments(r, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1"))
    }
    func testOwnershipRequiresAppAndScope() throws {
        let (v, r) = try fixture(); let o = actual(v, r); XCTAssertTrue(AppleRuntime.owns(o, record: r))
        XCTAssertFalse(AppleRuntime.owns(mutate("labels", ["dev.okdocker.app": r.id], o), record: r))
        XCTAssertFalse(AppleRuntime.owns(mutate("labels", ["dev.okdocker.app": "other", "dev.okdocker.scope": AppleRuntime.scope], o), record: r))
    }
    func testUnknownStateNotClaimedStopped() { XCTAssertTrue(AppleRuntime.active([:])); XCTAssertFalse(AppleRuntime.active(["status": ["state": "stopped"]])); XCTAssertTrue(AppleRuntime.active(["status": ["state": "starting"]])) }
    func testValidActualConfigurationAudits() throws { let (v, r) = try fixture(); XCTAssertNoThrow(try audit(actual(v, r), v, r)) }
    func testActualExtraMountRejected() throws {
        let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("mounts", [["source": "/Users", "destination": "/workspace", "options": []]], actual(v, r)), v, r))
    }
    func testActualExternalNetworkRejected() throws {
        let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("networks", [["network": "default"]], actual(v, r)), v, r))
    }
    func testActualPublicPortRejected() throws {
        let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("publishedPorts", [["hostAddress": "0.0.0.0", "hostPort": 19800, "containerPort": 8080, "proto": "tcp"]], actual(v, r)), v, r))
    }
    func testActualSSHAndRosettaRejected() throws {
        let (v, r) = try fixture()
        for key in ["ssh", "rosetta", "virtualization"] { XCTAssertThrowsError(try audit(mutate(key, true, actual(v, r)), v, r)) }
    }
    func testActualAddedCapabilitiesRejected() throws { let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("capAdd", ["ALL"], actual(v, r)), v, r)) }
    func testActualChangedApprovalRejected() throws { let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("labels", AppleRuntime.labels(r), actual(v, r)), v, r)) }
    func testSingleFileMountDoesNotExpandParentAuthorization() throws {
        let (v, r) = try fixture(); try Data("data".utf8).write(to: v.root.appendingPathComponent("file.txt"))
        var spec = v.manifest.services["app"]!; spec.mounts = [Mount(source: "file.txt", target: "/data/file.txt", readOnly: true)]
        XCTAssertThrowsError(try AppleRuntime.createArguments(r, service: "app", spec: spec, validated: v, image: "example/app:1"))
    }
    func testActualPublishedSocketRejected() throws {
        let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("publishedSockets", [["hostPath": "/tmp/not-approved", "containerPath": "/run/socket"]], actual(v, r)), v, r))
    }
    func testActualPortRangeRejected() throws {
        let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("publishedPorts", [["hostAddress": "127.0.0.1", "hostPort": 19800, "containerPort": 8080, "proto": "tcp", "count": 2]], actual(v, r)), v, r))
    }
    func testActualDroppedCapabilitiesRequired() throws { let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("capDrop", [], actual(v, r)), v, r)) }
    func testActualAlternativeRuntimeRejected() throws { let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("runtimeHandler", "other-runtime", actual(v, r)), v, r)) }
    func testActualAlternativePlatformRejected() throws { let (v, r) = try fixture(); XCTAssertThrowsError(try audit(mutate("platform", ["architecture": "amd64", "os": "linux"], actual(v, r)), v, r)) }
    func testInContainerRelayStaysInsideTheBackendContainer() throws {
        let (v, r) = try fixture()
        let guest = AppleRuntime.AndroidGuest(directory: "/tmp/okdocker-guest", hostSocket: "/tmp/okdocker.sock", command: ["python3", "-m", "http.server"])
        let args = try AppleRuntime.createArguments(r, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1", extraEnvironment: ["ADB_SERVER_SOCKET": AppleRuntime.adbSocketEnv], androidGuest: guest)
        XCTAssertTrue(args.contains("--entrypoint")); XCTAssertTrue(args.contains(AppleRuntime.relayExecutable))
        XCTAssertTrue(args.contains("ADB_SERVER_SOCKET=" + AppleRuntime.adbSocketEnv))
        XCTAssertFalse(args.contains("--publish-socket")); XCTAssertFalse(args.contains("okdocker-adb"))
        XCTAssertEqual(Array(args.suffix(7)), ["example/app:1", "--config", AppleRuntime.relayConfigPath, "--", "python3", "-m", "http.server"])
    }
    func testNewContainerDoesNotUseTheLegacyPeerSocket() throws {
        let (v, r) = try fixture()
        let args = try AppleRuntime.createArguments(r, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1")
        XCTAssertFalse(args.contains("--entrypoint")); XCTAssertFalse(args.joined(separator: "\n").contains("/run/okdocker-adb.sock"))
    }
    func testUnexpectedJSONShapeRejected() { XCTAssertThrowsError(try AppleRuntime.array("{}")); XCTAssertThrowsError(try AppleRuntime.array("warning\n[]")) }
}
