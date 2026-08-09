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

            // Leave by double tapping the diagram, which is the gesture for a hand already on
            // the glass. The diagram's label is the junction's name once it has built, so tap
            // by position rather than by looking the element up.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()

            XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 10),
                          "did not return to the map on attempt \(attempt)")
            // And specifically *not* all the way out to the home screen.
            XCTAssertFalse(app.navigationBars["TactileNav"].exists,
                           "attempt \(attempt) fell through to the home screen")
        }
    }

    /// Opening one junction, going back, then opening a *different* one stays in the map.
    ///
    /// This is the harder half of the same-junction case above: reopening the same junction
    /// leaves the binding unchanged, so only a different one exercises the push-after-pop path.
    ///
    /// **This does not reproduce the reported fall-through to the home screen** — the pre-fix
    /// code passes it too. It is kept as a guard on the path rather than as proof of a fix. The
    /// reported failure needs the destination builder to come up empty, which needs `phase` to
    /// be anything but `.ready` at the moment the push is evaluated, and the map loads far too
    /// quickly here for that to happen. The fix works by making the builder total instead — see
    /// `PortlandMapScreen.OpenJunction` — so there is no state left in which it can be empty.
    @MainActor
    func testOpeningADifferentJunctionAfterGoingBackStaysInTheMap() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Congress Square"))
            .firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 20))

        let map = app.scrollViews.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))

        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.navigationBars["Intersection"].waitForExistence(timeout: 10),
                      "the first junction did not open")
        // Left by double tapping the diagram, which is the gesture a hand already on the glass
        // uses — and the one the report came from.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 10))

        // A different junction, at an offset worked out from the extract rather than guessed:
        // the map opens on Congress at High, and these are where its neighbours land on a
        // phone-sized viewport. The list is a fallback chain because the viewport height
        // depends on the device, which shifts the vertical offsets.
        var opened = false
        for offset in [CGVector(dx: 0.797, dy: 0.293),   // Congress at Forest Avenue
                       CGVector(dx: 0.568, dy: 0.463),   // Congress at Free Street
                       CGVector(dx: 0.75, dy: 0.35),
                       CGVector(dx: 0.62, dy: 0.42)] {
            map.coordinate(withNormalizedOffset: offset).doubleTap()
            if app.navigationBars["Intersection"].waitForExistence(timeout: 6) {
                opened = true
                break
            }
            XCTAssertFalse(app.navigationBars["TactileNav"].exists,
                           "a second junction fell through to the home screen")
            XCTAssertTrue(app.navigationBars["Congress Square"].exists,
                          "left the map without opening anything")
        }
        XCTAssertTrue(opened, "no second junction could be opened")
        XCTAssertFalse(app.navigationBars["TactileNav"].exists,
                       "opening a second junction landed on the home screen")
    }

    /// The junction can also be left by pressing Back.
    ///
    /// The gestures are for a hand already on the glass; the button is for everyone else —
    /// Switch Control, a keyboard, a pointer, or anyone who simply looks for one. It is a
    /// custom button rather than the system's, so that it runs the same teardown the gestures
    /// do, which is exactly why it needs its own test.
    @MainActor
    func testTheBackButtonLeavesTheIntersection() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Congress Square"))
            .firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 20))

        let map = app.scrollViews.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.navigationBars["Intersection"].waitForExistence(timeout: 10))

        let back = app.navigationBars["Intersection"].buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the junction has no Back button")
        back.tap()

        XCTAssertTrue(app.navigationBars["Congress Square"].waitForExistence(timeout: 10),
                      "Back did not return to the map")
        XCTAssertFalse(app.navigationBars["TactileNav"].exists,
                       "Back fell through to the home screen")
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
