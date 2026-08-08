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

    /// Double-tapping a junction on the map opens its close-up.
    ///
    /// Taps the middle of the map, where the opening viewport puts Congress at High. The
    /// double tap has a wide catch radius on purpose, so this does not need pixel accuracy.
    @MainActor
    func testDoubleTapOpensTheIntersectionCloseUp() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Congress Square"))
            .firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 20))

        // The junction sits at the centre of the opening viewport, so tap the middle of the
        // scroll view itself — the window's centre is lower, because of the navigation bar.
        let map = app.scrollViews.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5), "no map scroll view:\n\(app.debugDescription)")
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()

        XCTAssertTrue(app.navigationBars["Intersection"].waitForExistence(timeout: 10),
                      "the double tap did not open the intersection")
        attach(app, named: "04-intersection-detail")
    }

    /// Opening a junction, leaving, and opening one again has to land on the junction.
    ///
    /// It used to land on the home screen: the `navigationDestination` was registered inside a
    /// conditional branch, so popping back deregistered it and SwiftUI emptied the stack.
    @MainActor
    func testAJunctionCanBeOpenedAgainAfterGoingBack() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Congress Square"))
            .firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 20))

        let map = app.scrollViews.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let middle = map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        for attempt in 1...2 {
            middle.doubleTap()
            XCTAssertTrue(app.navigationBars["Intersection"].waitForExistence(timeout: 10),
                          "the junction did not open on attempt \(attempt)")

            // Back is a double tap anywhere on the diagram — there is no back button. The
            // diagram's label is the junction's name once it has built, so tap by position
            // rather than by looking the element up.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()

            XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 10),
                          "did not return to the map on attempt \(attempt)")
            // And specifically *not* all the way out to the home screen.
            XCTAssertFalse(app.navigationBars["TactileNav"].exists,
                           "attempt \(attempt) fell through to the home screen")
        }
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
