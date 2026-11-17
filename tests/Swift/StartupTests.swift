import XCTest
import Darwin
@testable import OkDocker

final class StartupTests: XCTestCase {
    func app() throws -> AppRecord {
        let app = AppRecord(id: "startup-test-" + UUID().uuidString, root: "/tmp", name: "Fixture", project: "fixture", context: AppleRuntime.context, autoStart: false, manifestHash: "fixture", importedAt: Date())
        try FileManager.default.createDirectory(at: Runtime.appDirectory(app), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: Runtime.appDirectory(app)) }
        return app
    }
    func testActualStartLockOverridesStoppedContainersAndStaleMetadataCannotFakeStartup() throws {
        let app = try app(); try Startup.begin(app)
        let fd = open(Runtime.appDirectory(app).appendingPathComponent("start.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        Startup.phase(app, "Building fixture")
        let state = try Runtime.observe(app)
        XCTAssertEqual(state.state, "starting"); XCTAssertEqual(state.detail, "Building fixture"); XCTAssertNil(state.healthy)
        flock(fd, LOCK_UN)
        XCTAssertFalse(Startup.active(app)); XCTAssertNil(Startup.observation(app))
    }
    func testCommandOutputIsVisibleBeforeExitAndRetainedOnFailure() async throws {
        let app = try app(); try Startup.begin(app); let file = Startup.log(app)
        let command = Task.detached { try Runtime.command("/bin/sh", ["-c", "printf FIRST; sleep 1; printf SECOND; exit 7"], liveLog: file) }
        var live = false
        for _ in 0..<50 {
            if Startup.tail(file).contains("FIRST") { live = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(live); XCTAssertFalse(Startup.tail(file).contains("SECOND"))
        do { _ = try await command.value; XCTFail("Expected command failure") } catch {}
        XCTAssertTrue(Startup.tail(file).contains("FIRSTSECOND"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testLogTailIsBounded() throws {
        let app = try app(); let file = Startup.log(app)
        try Runtime.write(Data((String(repeating: "a", count: 1000) + "END").utf8), to: file)
        XCTAssertEqual(Startup.tail(file, limit: 10), "aaaaaaaEND")
    }
}
