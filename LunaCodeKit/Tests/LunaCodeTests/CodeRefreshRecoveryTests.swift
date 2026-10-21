import XCTest
import LunaCodeCore
@testable import LunaCodeMac
final class CodeRefreshRecoveryTests: XCTestCase {
    func testDefinitivelyInvalidArtifactMayRebuildButUnknownInstallationMustReconcile() {
        let target = CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/repo/App.xcodeproj", scheme: "App"), branch: "main", generation: "g")
        var job = CodeOvernightJob(requestID: "r", invocationID: "i", target: target)
        job.artifact = CodeBuildArtifact(id: "a", jobID: job.id, target: target, bundleID: "example.app", version: "1", build: "1", commit: "c", digest: "d", signingAuthority: "development", byteCount: 1)
        job.state = .failed; job.error = CodeOvernightError(.integrity, stage: "artifact", recovery: "Profile expired")
        XCTAssertTrue(CodeOvernightService.canReplaceFailedArtifact(job))
        var attempt = CodeInstallAttempt(artifactID: "a", provider: .native); attempt.state = .unknownCompletion
        job.installs = [attempt]
        XCTAssertFalse(CodeOvernightService.canReplaceFailedArtifact(job))
        job.installs = []; job.state = .waitingForPhone
        XCTAssertFalse(CodeOvernightService.canReplaceFailedArtifact(job))
        job.state = .failed; job.error = CodeOvernightError(.transport, stage: "connection", recovery: "Reconnect")
        XCTAssertFalse(CodeOvernightService.canReplaceFailedArtifact(job))
    }
}
