import XCTest
@testable import FeedIngest

final class SightingDeduperTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSameVehicleAtSameCameraIsRecordedOncePerWindow() {
        var d = SightingDeduper(window: 600)
        let k = SightingDeduper.key(source: "cam1", agencyKey: "US-MN/minneapolis/police", unit: "222", plate: nil, vehicleClass: "patrol")
        XCTAssertTrue(d.shouldRecord(key: k, now: t0))
        XCTAssertFalse(d.shouldRecord(key: k, now: t0.addingTimeInterval(2)), "next poll, same parked car")
        XCTAssertFalse(d.shouldRecord(key: k, now: t0.addingTimeInterval(599)))
        XCTAssertTrue(d.shouldRecord(key: k, now: t0.addingTimeInterval(601)), "still there after a window: logged again")
        XCTAssertFalse(d.shouldRecord(key: k, now: t0.addingTimeInterval(602)))
    }

    func testDifferentCameraOrVehicleIsNotSuppressed() {
        var d = SightingDeduper()
        let a = SightingDeduper.key(source: "cam1", agencyKey: "US-MN/minneapolis/police", unit: "222", plate: nil, vehicleClass: "patrol")
        let otherCam = SightingDeduper.key(source: "cam2", agencyKey: "US-MN/minneapolis/police", unit: "222", plate: nil, vehicleClass: "patrol")
        let otherUnit = SightingDeduper.key(source: "cam1", agencyKey: "US-MN/minneapolis/police", unit: "223", plate: nil, vehicleClass: "patrol")
        XCTAssertTrue(d.shouldRecord(key: a, now: t0))
        XCTAssertTrue(d.shouldRecord(key: otherCam, now: t0))
        XCTAssertTrue(d.shouldRecord(key: otherUnit, now: t0))
    }

    func testKeyFallsBackToClassWhenNothingIdentifiesTheVehicle() {
        XCTAssertEqual(SightingDeduper.key(source: "s", agencyKey: nil, unit: nil, plate: nil, vehicleClass: "fireEngine"), "s#class:fireEngine")
        XCTAssertEqual(SightingDeduper.key(source: "s", agencyKey: "US-TX/austin/fire", unit: nil, plate: "D756", vehicleClass: "x"),
                       "s#US-TX/austin/fire|plate:D756")
    }

    func testMemoryStaysBounded() {
        var d = SightingDeduper(window: 600, maxEntries: 100)
        for i in 0..<1_000 { _ = d.shouldRecord(key: "k\(i)", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertLessThanOrEqual(d.trackedCount, 100, "expired and oldest entries are dropped")
    }
}
