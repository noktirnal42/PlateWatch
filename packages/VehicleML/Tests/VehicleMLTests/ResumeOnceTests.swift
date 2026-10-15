import XCTest
@testable import VehicleML

final class ResumeOnceTests: XCTestCase {
    struct Boom: Error {}

    /// The Hub crash: a failure reported twice (completion handler, then a thrown error) must not trap, and the first
    /// result wins.
    func testSecondResumeIsIgnoredAndFirstWins() async {
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                once.resume(throwing: Boom())
                once.resume(throwing: Boom())
                once.resume(returning: 7)
            }
            XCTFail("expected the first (thrown) result")
        } catch { XCTAssertTrue(error is Boom) }
    }

    func testValueThenErrorKeepsValue() async throws {
        let v: Int = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            once.resume(returning: 7)
            once.resume(throwing: Boom())
        }
        XCTAssertEqual(v, 7)
    }
}
