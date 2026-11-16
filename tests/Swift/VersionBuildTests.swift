import XCTest
@testable import OkDocker

final class VersionBuildTests: XCTestCase {
    func fixture() throws -> (URL, Validated, AppRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let endpoint: [String: Any] = ["service": "app", "directory": ".", "path": "/", "hostPort": 19800, "containerPort": 8080]
        let object: [String: Any] = ["schemaVersion": 1, "version": "1.0.0", "id": "demo", "name": "Demo", "frontend": endpoint, "backend": endpoint, "services": ["app": ["image": "example/app:1"]]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("okdocker.json"))
        try Data("FROM example/build:1\nWORKDIR /src\nCOPY . .\n# okdocker:build-script\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        try Data("printf built\n".utf8).write(to: root.appendingPathComponent("build.sh"))
        let v = try validate(root: root)
        var r = AppRecord(id: "fixture", root: root.path, name: "Demo", project: "okdocker-fixture", context: AppleRuntime.context, autoStart: false, manifestHash: v.hash, importedAt: Date())
        r.approvalHash = try v.approvalHash(); r.manifestVersion = v.manifest.version
        return (root, v, r)
    }
    func change(_ root: URL, _ update: (inout [String: Any]) -> Void) throws -> Validated {
        let file = root.appendingPathComponent("okdocker.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        update(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return try validate(root: root)
    }
    func testApplicationVersionSeparateFromSchema() throws { let (_, v, _) = try fixture(); XCTAssertEqual(v.manifest.version, "1.0.0"); XCTAssertEqual(v.manifest.schemaVersion, 1) }
    func testInvalidVersionsRejected() throws {
        let (root, _, _) = try fixture()
        for value: Any in ["", " with space", "../escape", "v1\n", String(repeating: "a", count: 65), 1] { XCTAssertThrowsError(try change(root) { $0["version"] = value }) }
    }
    func testLegacyVersionOptional() throws { let (root, _, _) = try fixture(); XCTAssertNil(try change(root) { $0.removeValue(forKey: "version") }.manifest.version) }
    func testVersionDoesNotExpandAuthorization() throws {
        let (root, v, _) = try fixture()
        let next = try change(root) { $0["version"] = "2.0.0+build-1" }
        XCTAssertNotEqual(v.hash, next.hash); XCTAssertEqual(try v.approvalHash(), try next.approvalHash())
        let permission = try change(root) { $0["hostAndroidDevices"] = true }
        XCTAssertNotEqual(try v.approvalHash(), try permission.approvalHash())
    }
    func testEveryOtherSettingRemainsSealed() throws {
        let (_, v, _) = try fixture()
        for field in ["command", "environment", "mounts", "build", "ports", "name"] {
            var m = v.manifest
            switch field {
            case "command": m.services["app"]!.command = ["sh"]
            case "environment": m.services["app"]!.environment = ["SECRET": "not-real"]
            case "mounts": m.services["app"]!.mounts = []
            case "build": m.services["app"]!.build = BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh")
            case "ports": m.backend.hostPort = 19801
            default: m.name = "Changed"
            }
            let changed = Validated(root: v.root, manifest: m, hash: v.hash, icon: nil)
            XCTAssertNotEqual(try v.approvalHash(), try changed.approvalHash(), field)
        }
    }
    func testSameVersionReusesAndChangedVersionReplaces() throws {
        let (root, v, r) = try fixture()
        XCTAssertFalse(VersionDeployment.needsReplacement(r, desired: v, existing: []))
        let next = try change(root) { $0["version"] = "2.0.0" }
        XCTAssertTrue(VersionDeployment.needsReplacement(r, desired: next, existing: []))
    }
    func testActualContainerVersionCheckedEvenAfterReimport() throws {
        let (_, v, r) = try fixture()
        let old: [String: Any] = ["configuration": ["labels": ["dev.okdocker.service": "app", "dev.okdocker.version": "0.9.0"]]]
        XCTAssertTrue(VersionDeployment.needsReplacement(r, desired: v, existing: [old]))
        let shared: [String: Any] = ["configuration": ["labels": ["dev.okdocker.service": "okdocker-adb"]]]
        XCTAssertFalse(VersionDeployment.needsReplacement(r, desired: v, existing: [shared]))
    }
    func testFreshDeploymentNamesAndVersionLabels() throws {
        let (_, v, r) = try fixture(); var next = r; next.deployment = "new-generation"
        XCTAssertNotEqual(AppleRuntime.name(r, "app"), AppleRuntime.name(next, "app"))
        XCTAssertEqual(AppleRuntime.name(r, "okdocker-adb"), AppleRuntime.name(next, "okdocker-adb"))
        let args = try AppleRuntime.createArguments(next, service: "app", spec: v.manifest.services["app"]!, validated: v, image: "example/app:1")
        XCTAssertTrue(args.contains("dev.okdocker.version=1.0.0")); XCTAssertTrue(args.contains("dev.okdocker.deployment=new-generation"))
    }
    func testLongServiceNamesRemainUniqueAndWithinHostnameLimit() throws {
        let (_, _, r) = try fixture(); var next = r; next.project = "okdocker-123456789abc"; next.deployment = String(repeating: "d", count: 32)
        let first = AppleRuntime.name(next, String(repeating: "a", count: 41))
        let second = AppleRuntime.name(next, String(repeating: "a", count: 40) + "b")
        XCTAssertLessThanOrEqual(first.utf8.count, 63); XCTAssertNotEqual(first, second)
    }
    func testRegistryBackwardCompatibility() throws {
        let (_, _, r) = try fixture(); var old = r; old.approvalHash = nil; old.manifestVersion = nil; old.deployment = nil
        let restored = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(old))
        XCTAssertNil(restored.approvalHash); XCTAssertNil(restored.manifestVersion); XCTAssertNil(restored.deployment)
    }
    func testScriptDeclarationValidated() throws {
        let (root, _, _) = try fixture()
        let v = try change(root) { $0["services"] = ["app": ["build": ["context": ".", "dockerfile": "Dockerfile", "script": "build.sh"]]] }
        XCTAssertEqual(v.manifest.services["app"]?.build?.script, "build.sh")
    }
    func testScriptCannotEscapeContext() throws {
        let (root, _, _) = try fixture()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.sh"), withDestinationURL: root.deletingLastPathComponent())
        for path in ["../build.sh", "/bin/sh", "outside.sh", ".", "missing.sh"] {
            XCTAssertThrowsError(try change(root) { $0["services"] = ["app": ["build": ["context": ".", "dockerfile": "Dockerfile", "script": path]]] })
        }
    }
    func testScriptExecInstructionAndSourceUnchanged() throws {
        let (root, _, _) = try fixture(); let file = root.appendingPathComponent("Dockerfile"); let original = try Data(contentsOf: file)
        let data = try XCTUnwrap(BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: file))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("RUN [\"/bin/sh\",\"./build.sh\"]"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testScriptPathIsNotShellExpansion() throws {
        let (root, _, _) = try fixture(); let path = "$(touch BAD) with spaces.sh"
        try Data("exit 0\n".utf8).write(to: root.appendingPathComponent(path))
        let rendered = try XCTUnwrap(BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: path), context: root, dockerfile: root.appendingPathComponent("Dockerfile")))
        XCTAssertTrue(String(decoding: rendered, as: UTF8.self).contains("./$(touch BAD) with spaces.sh")); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BAD").path))
    }
    func testMissingDuplicateAndContinuedMarkersRejected() throws {
        let (root, _, _) = try fixture(); let file = root.appendingPathComponent("Dockerfile")
        for text in ["FROM scratch\n", "# okdocker:build-script\n# okdocker:build-script\n", "RUN echo \\\n# okdocker:build-script\n"] {
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: file))
        }
    }
    func testDockerfileSpecificIgnorePreservedAndScratchRemoved() throws {
        let (root, _, _) = try fixture(); let file = root.appendingPathComponent("Dockerfile")
        try Data("credentials\n*.sqlite\n".utf8).write(to: root.appendingPathComponent("Dockerfile.dockerignore"))
        var generated: URL?
        try BuildRecipe.withDockerfile(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: file, scratch: root.appendingPathComponent("scratch")) { url in
            generated = url
            XCTAssertEqual(try String(contentsOfFile: url.path + ".dockerignore", encoding: .utf8), "credentials\n*.sqlite\n")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(generated).path))
    }
    func testPythonShebangRespected() throws {
        let (root, _, _) = try fixture()
        try Data("#!/usr/bin/env python3\nprint('build')\n".utf8).write(to: root.appendingPathComponent("build.sh"))
        let data = try XCTUnwrap(BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: root.appendingPathComponent("Dockerfile")))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("RUN [\"/usr/bin/env\",\"python3\",\"./build.sh\"]"))
    }
    func testShebangOptionalArgumentIsNotShellParsed() throws {
        let (root, _, _) = try fixture()
        try Data("#!/usr/bin/env -S python3 -I\nprint('build')\n".utf8).write(to: root.appendingPathComponent("build.sh"))
        let data = try XCTUnwrap(BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: root.appendingPathComponent("Dockerfile")))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"-S python3 -I\""))
    }
    func testRelativeShebangInterpreterRejected() throws {
        let (root, _, _) = try fixture()
        try Data("#!bash\necho build\n".utf8).write(to: root.appendingPathComponent("build.sh"))
        XCTAssertThrowsError(try BuildRecipe.render(BuildSpec(context: ".", dockerfile: "Dockerfile", script: "build.sh"), context: root, dockerfile: root.appendingPathComponent("Dockerfile")))
    }
    func testNoScriptKeepsOriginalDockerfile() throws {
        let (root, _, _) = try fixture(); let file = root.appendingPathComponent("Dockerfile")
        try BuildRecipe.withDockerfile(BuildSpec(context: ".", dockerfile: "Dockerfile"), context: root, dockerfile: file, scratch: root) { XCTAssertEqual($0, file) }
    }
}
