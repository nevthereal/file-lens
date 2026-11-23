import XCTest
@testable import FileLens

final class IndexingStatusTests: XCTestCase {
    func testEstimateWaitsForMeaningfulProgressAndWarmup() {
        var status = IndexingStatus()
        status.start(scope: "Drive", now: 100)
        XCTAssertNil(status.fraction)
        XCTAssertNil(status.remaining(at: 105))
        status.update(0.25)
        XCTAssertNil(status.remaining(at: 102))
        XCTAssertEqual(status.remaining(at: 110), 30)
        XCTAssertEqual(status.elapsed(at: 110), 10)
    }

    func testProgressIsMonotonicAndOnlyCompletionReachesOneHundred() {
        var status = IndexingStatus()
        status.start(scope: "Drive", now: 0)
        status.update(0.4)
        status.update(0.2)
        status.update(.nan)
        XCTAssertEqual(status.fraction, 0.4)
        status.update(1)
        XCTAssertLessThan(status.fraction!, 1)
        status.stop(.complete, now: 20)
        XCTAssertEqual(status.fraction, 1)
        XCTAssertNil(status.remaining(at: 30))
        XCTAssertEqual(status.elapsed(at: 30), 20)
    }

    func testPauseFreezesElapsedAndNewScopeResetsEstimate() {
        var status = IndexingStatus()
        status.start(scope: "Drive", now: 0)
        status.update(0.25)
        status.stop(.paused, now: 10)
        status.update(0.8)
        XCTAssertEqual(status.elapsed(at: 100), 10)
        XCTAssertEqual(status.fraction, 0.25)
        XCTAssertNil(status.remaining(at: 100))
        status.start(scope: "Folder", now: 100)
        XCTAssertEqual(status.scope, "Folder")
        XCTAssertEqual(status.phase, .running)
        XCTAssertNil(status.fraction)
        XCTAssertEqual(status.elapsed(at: 101), 1)
    }

    func testResumeExcludesPausedTime() {
        var status = IndexingStatus()
        status.start(scope: "Drive", now: 0)
        status.update(0.5)
        status.stop(.paused, now: 10)
        status.resume(now: 100)
        XCTAssertEqual(status.phase, .running)
        XCTAssertEqual(status.elapsed(at: 105), 15)
        XCTAssertEqual(status.fraction, 0.5)
        XCTAssertEqual(status.remaining(at: 105), 15)
    }

    func testTimeFormattingMakesEstimateApproximate() {
        XCTAssertEqual(IndexingStatus.elapsedText(65), "1m 5s")
        XCTAssertEqual(IndexingStatus.elapsedText(3660), "1h 1m")
        XCTAssertEqual(IndexingStatus.remainingText(63), "~2 min remaining")
        XCTAssertEqual(IndexingStatus.remainingText(11), "~15 sec remaining")
    }
}
