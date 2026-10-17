import XCTest

final class ReviewFlowTests: XCTestCase {
    @MainActor private func preview(tab: Int, extraArguments: [String] = []) -> XCUIApplication {
        // XCTest may run methods in a different order, and the landscape test
        // leaves the simulator rotated. Reset before every preview so large
        // text/accessibility checks exercise the intended portrait layout.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-PWPreviewData", "-PWTab", String(tab)] + extraArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["DEMO DATA · LOCAL PREVIEW"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testObservationDetailRetryAndDiscard() {
        let app = preview(tab: 1)
        capture("ios-sightings", app)
        app.buttons["sighting-preview-0"].tap()
        XCTAssertTrue(app.staticTexts["Coarse area"].waitForExistence(timeout: 5))
        capture("ios-observation", app)
        let resume = app.buttons["Resume automatic retries"]
        if !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.isHittable)
        resume.tap()
        XCTAssertTrue(app.staticTexts["Sync status: Queued"].exists)
        let discard = app.buttons["Discard queued copy"]
        discard.tap()
        let confirm = app.sheets.buttons["Discard queued copy"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Waiting to send · 1"].waitForExistence(timeout: 5))
    }

    @MainActor func testWatchlistValidationAddMuteAndDelete() {
        let app = preview(tab: 2)
        capture("ios-watchlist", app)
        let field = app.textFields["fleet-plate-input"]
        field.tap(); field.typeText("demo1")
        dismissWatchlistKeyboard(app)
        XCTAssertTrue(app.staticTexts["This plate is already on your watchlist."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add to watchlist"].isEnabled)
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "GOV123")
        XCTAssertFalse(app.buttons["Add to watchlist"].isEnabled)
        dismissWatchlistKeyboard(app)
        XCTAssertEqual(field.value as? String, "GOV123")
        app.switches["fleet-attestation"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Add to watchlist"].isEnabled)
        app.buttons["Add to watchlist"].tap()
        XCTAssertTrue(app.staticTexts["Watching · 3"].waitForExistence(timeout: 5))
        let mute = app.buttons["Mute alerts for GOV123"]
        if !mute.isHittable { app.swipeUp() }
        mute.tap()
        XCTAssertTrue(app.buttons["Enable alerts for GOV123"].exists)
        let row = app.cells.containing(.button, identifier: "Enable alerts for GOV123").firstMatch
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Watching · 2"].exists)
    }

    @MainActor func testLocalDataCleanup() {
        let app = preview(tab: 4)
        capture("ios-about", app)
        let clear = app.buttons["Clear local queue & watchlist"]
        if !clear.isHittable { app.swipeUp() }
        clear.tap()
        app.buttons["Clear queue & watchlist"].tap()
        app.tabBars.buttons["Sightings"].tap()
        XCTAssertTrue(app.staticTexts["Your queue is clear"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Watchlist"].tap()
        XCTAssertTrue(app.staticTexts["No fleet plates on watch yet"].waitForExistence(timeout: 5))
    }

    @MainActor func testOnboardingCanContinueWithoutPermissionsInPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-PWPreviewData", "-PWPreviewOnboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Watch the public fleet."].waitForExistence(timeout: 10))
        capture("ios-onboarding", app)
        let start = app.buttons["Get started"]
        if !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.staticTexts["DEMO DATA · LOCAL PREVIEW"].waitForExistence(timeout: 5))
    }

    @MainActor func testDarkLargeTypeWatchlist() {
        let app = preview(tab: 2, extraArguments: ["-PWPreviewDark", "-PWPreviewLargeText"])
        capture("ios-watchlist-dark-large-text", app)
        let field = app.textFields["fleet-plate-input"]
        if !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        // Dynamic Type can place the SwiftUI field inside a List cell whose
        // accessibility tap does not promote the UIKit responder on iOS 27.
        // A coordinate tap exercises the same visible control and is stable
        // across the large-text layout.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        field.typeText("GOV123")
        dismissWatchlistKeyboard(app)
        let attestation = app.switches["fleet-attestation"]
        // Large Dynamic Type can leave the toggle below the first viewport
        // after keyboard dismissal. Scroll only as far as needed, with a
        // bounded loop so the test exercises the real accessibility path.
        for _ in 0..<4 where !attestation.isHittable { app.swipeUp() }
        XCTAssertTrue(attestation.isHittable)
        capture("ios-watchlist-dark-large-text-controls", app)
    }

    @MainActor func testLandscapeWatchlist() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = preview(tab: 2)
        XCTAssertTrue(app.textFields["fleet-plate-input"].exists)
        capture("ios-watchlist-landscape", app)
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func dismissWatchlistKeyboard(_ app: XCUIApplication) {
        let toolbarDone = app.buttons["watchlist-keyboard-done"]
        if toolbarDone.waitForExistence(timeout: 2) && toolbarDone.isHittable {
            toolbarDone.tap()
        } else {
            let keyboardDone = app.keyboards.buttons["done"]
            XCTAssertTrue(keyboardDone.waitForExistence(timeout: 2))
            keyboardDone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
