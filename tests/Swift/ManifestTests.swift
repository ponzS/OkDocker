import XCTest
import Darwin
@testable import OkDocker

final class ManifestTests: XCTestCase {
    func fixture(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object: [String: Any] = ["schemaVersion": 1, "id": "demo", "name": "Demo",
            "frontend": ["service": "app", "directory": ".", "path": "/", "hostPort": 18080, "containerPort": 8080],
            "backend": ["service": "app", "directory": ".", "path": "/health", "hostPort": 18080, "containerPort": 8080],
            "services": ["app": ["image": "example/app:1"]]]
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("okdocker.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testValidMinimalConfiguration() throws { XCTAssertEqual(try validate(root: fixture()).manifest.name, "Demo") }
    func testParentMountRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["image": "example/app:1", "mounts": [["source": "..", "target": "/workspace"]]]] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testAbsoluteMountRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["image": "example/app:1", "mounts": [["source": "/Users", "target": "/workspace"]]]] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testSymlinkEscapeRejected() throws {
        let root = try fixture()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try contained("outside", root: root))
    }
    func testPrivilegedRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["image": "example/app:1", "privileged": true]] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testUnknownPermissionRejected() throws { XCTAssertThrowsError(try validate(root: fixture { $0["hostDevices"] = true })) }
    func testExternalDockerfileRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["build": ["context": ".", "dockerfile": "../Dockerfile"]]] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testPortCollisionInManifestRejected() throws {
        let root = try fixture { $0["backend"] = ["service": "app", "directory": ".", "path": "/health", "hostPort": 18080, "containerPort": 8081] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testMissingEndpointServiceRejected() throws {
        let root = try fixture { $0["backend"] = ["service": "missing", "directory": ".", "path": "/health", "hostPort": 18080, "containerPort": 8080] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testBrowserURLCannotEscapeLocalhost() throws {
        let root = try fixture { $0["frontend"] = ["service": "app", "directory": ".", "path": "//evil.example/", "hostPort": 18080, "containerPort": 8080] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testUnknownEndpointFieldRejected() throws {
        let root = try fixture { var endpoint = $0["frontend"] as! [String: Any]; endpoint["host"] = "0.0.0.0"; $0["frontend"] = endpoint }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testUnknownMountPermissionRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["image": "example/app:1", "mounts": [["source": ".", "target": "/workspace", "recursive": true]]]] }
        XCTAssertThrowsError(try validate(root: root))
    }
    func testUnknownBuildCapabilityRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["build": ["context": ".", "dockerfile": "Dockerfile", "ssh": "default"]]] }
        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        XCTAssertThrowsError(try validate(root: root))
    }
    func testInterpolationIsEscaped() {
        let out = Runtime.escaped(["command": ["echo", "${HOME}", "a$b"], "environment": ["VALUE": "$SECRET"]]) as! [String: Any]
        XCTAssertEqual(out["command"] as? [String], ["echo", "$${HOME}", "a$$b"])
        XCTAssertEqual((out["environment"] as? [String: String])?["VALUE"], "$$SECRET")
    }
    private func assertListenerIsNotFree(_ host: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var reuse: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr(host)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        XCTAssertEqual(result, 0)
        XCTAssertThrowsError(try Runtime.requireFreePort(Int(address.sin_port.bigEndian)))
    }
    func testWildcardListenerIsNotMistakenForFree() throws { try assertListenerIsNotFree("0.0.0.0") }
    func testLoopbackListenerIsNotMistakenForFree() throws { try assertListenerIsNotFree("127.0.0.1") }
    func testContainerDeviceTargetRejected() throws {
        let root = try fixture { $0["services"] = ["app": ["image": "example/app:1", "mounts": [["source": ".", "target": "/dev"]]]] }
        XCTAssertThrowsError(try validate(root: root))
    }
}
