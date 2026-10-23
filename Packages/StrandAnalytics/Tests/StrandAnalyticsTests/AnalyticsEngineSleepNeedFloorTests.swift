import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Public `analyzeDay` contract for degenerate sleep-need inputs. The mirrored Android test uses the
/// same provided 5-minute light-sleep session and asserts the same rounded Rest projection.
final class AnalyticsEngineSleepNeedFloorTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2025-06-10"
    private let sessionStart = 1_749_517_200

    private func rest(sleepNeedHours: Double) throws -> Double {
        let provided = SleepSession(
            start: sessionStart,
            end: sessionStart + 300,
            efficiency: 1,
            stages: [StageSegment(start: sessionStart, end: sessionStart + 300, stage: "light")],
            restingHR: nil,
            avgHRV: nil)

        return try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: day,
            profile: profile,
            sleepNeedHours: sleepNeedHours,
            providedSleep: [provided]
        ).restScore)
    }

    func testSleepNeedUsesPointOneHourFloorAtAndAcrossBoundary() throws {
        let cases: [(need: Double, expectedRest: Double)] = [
            // v2 zeroes duration at half the need, so the session is 5 min (above half of the 0.1 h
            // floor) for the floor to stay visible in the score.
            (-1.0, 54.49),
            (0.0, 54.49),
            (0.099, 54.49),
            (0.1, 54.49),
            (0.101, 53.59),
        ]

        let actual = try cases.map { try rest(sleepNeedHours: $0.need) }
        XCTAssertEqual(actual, cases.map(\.expectedRest))
    }
}
