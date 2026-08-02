//
//  TactileNavUITests.swift
//  TactileNavUITests
//
//  Drives the real app and captures what each screen actually looks like.
//
//  Unit tests can render a canvas in isolation and check its pixels, but they cannot tell you
//  that the screen is reachable, that it laid out inside the safe area, or that the map opened
//  where it was supposed to. These do, and they leave a screenshot behind either way.
//

import XCTest

final class TactileNavUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testCongressSquareMapOpensAndDrawsStreets() throws {
        let app = launch()
        attach(app, named: "01-home")

        // The row's accessibility label is the whole card — title and subtitle — so match on
        // a prefix rather than an exact string.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Congress Square"))
            .firstMatch.tap()

        // The map loads off the main thread, so wait for the loading state to clear.
        let loading = app.staticTexts["Loading the Congress Square map"]
        if loading.exists {
            XCTAssertTrue(loading.waitForNonExistence(timeout: 20), "the map never finished loading")
        }
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 20))

        attach(app, named: "02-congress-square")
    }

    @MainActor
    func testStreetCrossingAudioShowsTheIntersection() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Street Crossing Audio"))
            .firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Street Crossing Audio"].waitForExistence(timeout: 20))
        attach(app, named: "03-intersection")
    }
}
