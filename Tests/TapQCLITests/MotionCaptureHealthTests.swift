import XCTest
@testable import TapQCLI

final class MotionCaptureHealthTests: XCTestCase {
    func testTransientLossClearsAfterValidSample() {
        var health = MotionCaptureHealth()
        health.recordLoss()
        XCTAssertEqual(health.failure, .disconnected)

        health.recordSample()
        XCTAssertNil(health.failure)
        XCTAssertTrue(health.receivedSample)
        XCTAssertFalse(health.hasUnrecoveredLoss)
    }

    func testLossAfterSamplesRemainsAFailureUntilRecovery() {
        var health = MotionCaptureHealth()
        health.recordSample()
        health.recordLoss()
        XCTAssertEqual(health.failure, .disconnected)
    }

    func testNoSamplesIsReportedSeparately() {
        XCTAssertEqual(MotionCaptureHealth().failure, .noSamples)
    }
}
