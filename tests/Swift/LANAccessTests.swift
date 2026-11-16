import XCTest
import AppKit
@testable import OkDocker

final class LANAccessTests: XCTestCase {
    func record() -> AppRecord { AppRecord(id: "test", root: "/tmp/example", name: "Example", project: "okdocker-test", context: AppleRuntime.context, autoStart: false, manifestHash: "approved", importedAt: Date()) }
    func testPrivate10Addresses() { for ip in ["10.0.0.1", "10.255.255.254"] { XCTAssertTrue(LANAccess.isPrivateIPv4(ip)) } }
    func testPrivate172Boundaries() { XCTAssertTrue(LANAccess.isPrivateIPv4("172.16.0.1")); XCTAssertTrue(LANAccess.isPrivateIPv4("172.31.255.254")); XCTAssertFalse(LANAccess.isPrivateIPv4("172.15.0.1")); XCTAssertFalse(LANAccess.isPrivateIPv4("172.32.0.1")) }
    func testPrivate192Addresses() { XCTAssertTrue(LANAccess.isPrivateIPv4("192.168.10.124")); XCTAssertFalse(LANAccess.isPrivateIPv4("192.169.10.124")) }
    func testPublicWildcardLoopbackIPv6AndMalformedRejected() { for ip in ["0.0.0.0", "127.0.0.1", "8.8.8.8", "169.254.1.2", "100.64.1.2", "::1", "fe80::1", "10.0.0.256", "010.0.0.1", "192.168.1.01", "10..0.1", "10.1.2", "localhost", "10.1.2.3:80", "10.1.2.3/24"] { XCTAssertFalse(LANAccess.isPrivateIPv4(ip), ip) } }
    func testOnlyPhysicalEthernetAndWifiNames() { for name in ["en0", "en12"] { XCTAssertTrue(LANAccess.interfaceAllowed(name)) }; for name in ["lo0", "utun0", "bridge100", "vmenet0", "ap1", "awdl0", "en0;bad", "en"] { XCTAssertFalse(LANAccess.interfaceAllowed(name)) } }
    func testLANURLUsesApprovedPortAndPath() { let endpoint = Endpoint(service: "app", directory: ".", path: "/ui/", hostPort: 18080, containerPort: 8080); XCTAssertEqual(LANAccess.url(endpoint, host: "192.168.1.2")?.absoluteString, "http://192.168.1.2:18080/ui/"); XCTAssertNil(LANAccess.url(endpoint, host: "evil.example")); XCTAssertEqual(endpoint.url.host, "127.0.0.1") }
    func testOldRecordDefaultsOff() throws { let value = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(record())); XCTAssertNil(value.lanAccess); XCTAssertFalse(LANAccess.status(value).enabled) }
    func testLANConsentRoundTripsAndDoesNotChangeDeploymentHash() throws { var value = record(); value.lanAccess = true; let decoded = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(value)); XCTAssertEqual(decoded.lanAccess, true); XCTAssertEqual(decoded.manifestHash, "approved"); XCTAssertNotEqual(decoded, record()) }
    func testManifestCannotGrantLANPermission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint: [String: Any] = ["service": "app", "directory": ".", "path": "/", "hostPort": 18080, "containerPort": 8080]
        let object: [String: Any] = ["schemaVersion": 1, "id": "test", "name": "Example", "frontend": endpoint, "backend": endpoint, "services": ["app": ["image": "example/app:1"]], "lanAccess": true]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("okdocker.json")); XCTAssertThrowsError(try validate(root: root))
    }
    func rules() throws -> String { let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(); return try ConfigurationRules.text(resources: root) }
    func testCompleteGenericRulesHaveAIInstructions() throws {
        let text = try rules()
        XCTAssertTrue(text.contains("Using the OkDocker rules below"))
        for field in ["schemaVersion", "hostAndroidDevices", "containerPort", "Dockerfile", "Allow LAN access"] { XCTAssertTrue(text.contains(field), field) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chinese = try String(contentsOf: root.appendingPathComponent("zh/CONFIGURATION.md"), encoding: .utf8)
        XCTAssertTrue(chinese.contains("[English](../CONFIGURATION.md)"))
        XCTAssertTrue(chinese.contains("允许局域网访问"))
    }
    @MainActor func testCopiesCompleteRulesToPrivatePasteboard() async throws { let board = NSPasteboard.withUniqueName(); defer { board.clearContents() }; let text = try rules(); try ConfigurationRules.copy(text, to: board); XCTAssertEqual(board.string(forType: .string), text) }
}
