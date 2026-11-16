import XCTest

@MainActor
final class AccessibilityDiscoveryUITests: XCTestCase {
    private func launch(minimum: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES",
            "-WWUITestResetPreferences", "YES", "-WWUITestCenterWindows", "YES",
            "-WWUITestAutosave", "OFF", "-WWUITestOpenShow", "Accessibility Discovery",
            "-WWUITestShowFolder", "WWUITests-AccessibilityDiscovery-\(UUID().uuidString)",
            "-WWUITestShowEpisodes", "1", "-WWUITestSinglePrimaryFixture", "YES",
            "-WWUITestAlignmentFixture", "YES", "-WWUITestCleanupFixture", "YES",
            "-WWUITestCleanupTimelineFixture", "YES", "-WWUITestTranscriptFixture", "YES",
        ]
        if minimum { app.launchArguments += ["-WWUITestMinimumShowWindow", "YES"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["ww.review.toggle"].waitForExistence(timeout: 20))
        return app
    }

    private func record(_ app: XCUIApplication, _ name: String, values: [String: Any] = [:]) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-native-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        Acceptance.writeEvidence(name, values, test: self)
    }

    private func detachReview(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.buttons["ww.review.toggle"]
        if toggle.value as? String != "Shown" { toggle.click() }
        app.buttons["ww.review.detach"].click()
        let window = app.windows["ww.review.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        return window
    }

    func testDetachedReviewPresentsItsOwnFailure() {
        let app = launch()
        defer { app.terminate() }
        let review = detachReview(app)
        let action = review.buttons["Mark missed filler"]
        XCTAssertTrue(action.isEnabled)
        action.click()
        let message = "Select a speaker's waveform or word before marking a missed filler."
        let local = review.staticTexts[message]
        let anywhere = app.staticTexts[message].firstMatch
        _ = anywhere.waitForExistence(timeout: 3)
        record(app, "detached-review-operation-error", values: [
            "expectedMessage": message,
            "presentInReviewWindow": local.exists,
            "presentSomewhereInApplication": anywhere.exists,
            "reviewWindow": review.title,
        ])
        XCTAssertTrue(local.exists, "The initiating detached Review window must expose its recovery message.")
        let search = review.textFields["ww.review.search"]
        search.click()
        search.typeText("Um")
        search.typeKey(.tab, modifierFlags: [])
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.menuItems["All speakers"].waitForExistence(timeout: 3),
                      "Keyboard filter navigation remains available after the refusal.")
        app.typeKey(.escape, modifierFlags: [])
        let row = review.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.cleanup.filler.review.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(review.staticTexts["ww.review.error"].waitForNonExistence(timeout: 5),
                      "Selecting a usable review clears the shared operation failure.")
    }

    func testReviewHeadingGrowsWithTextSize() {
        let app = launch()
        defer { app.terminate() }
        let review = detachReview(app)
        let heading = review.staticTexts["Transcript & Review"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let original = heading.frame
        record(app, "review-text-100", values: ["headingFrame": "\(original)"])
        for _ in 0..<4 { app.typeKey("+", modifierFlags: .command) }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["ww.settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Workspace"].click()
        let selectedSize = settings.popUpButtons["ww.settings.textSize"].value as? String ?? ""
        XCTAssertEqual(selectedSize, "200%")
        settings.typeKey("w", modifierFlags: .command)
        let grown = heading.frame
        record(app, "review-text-200", values: [
            "selectedTextSize": selectedSize, "headingFrame100": "\(original)",
            "headingFrame200": "\(grown)",
        ])
        XCTAssertGreaterThan(grown.height, original.height * 1.5,
            "The Review heading itself must grow, not only the text-size preference or window chrome.")
        checkDetails(in: review, app: app, name: "detached-review-details-200")
    }

    func testMixerHeldPeakExposesAccessibleValue() {
        let app = launch()
        defer { app.terminate() }
        XCUIElement.perform(withKeyModifiers: .option) { app.buttons["ww.mixer.toggle"].click() }
        let peak = app.buttons["ww.mixer.strip.master.peak"]
        XCTAssertTrue(peak.waitForExistence(timeout: 5), app.debugDescription)
        let value = peak.value as? String ?? ""
        record(app, "mixer-held-peak", values: [
            "label": peak.label, "value": value,
            "identifier": peak.identifier, "frame": "\(peak.frame)",
            "signalState": "Idle; live-signal retention is not qualified by this check.",
        ])
        XCTAssertEqual(value, "No held peak measurement; no clipping latched")
        let gain = app.textFields["ww.mixer.strip.master.gain"]
        let originalGain = gain.frame
        let originalPeak = peak.frame
        for _ in 0..<4 { app.typeKey("+", modifierFlags: .command) }
        XCTAssertTrue(wait { gain.frame.height > originalGain.height * 1.5 })
        XCTAssertGreaterThan(peak.frame.height, originalPeak.height * 1.5)
        record(app, "mixer-readouts-text-200", values: [
            "gainFrame100": "\(originalGain)", "gainFrame200": "\(gain.frame)",
            "heldPeakFrame100": "\(originalPeak)", "heldPeakFrame200": "\(peak.frame)",
        ])
    }

    func testReviewDetailsRemainReadableDockedAndDetachedAtMinimumSize() {
        let app = launch(minimum: true)
        defer { app.terminate() }
        let main = app.windows["ww.show.window"]
        app.buttons["ww.review.toggle"].click()
        checkDetails(in: main, app: app, name: "docked-review-details-100-minimum")
        for _ in 0..<4 { app.typeKey("+", modifierFlags: .command) }
        checkDetails(in: main, app: app, name: "docked-review-details-200-minimum")
        XCUIElement.perform(withKeyModifiers: .option) { app.buttons["ww.review.toggle"].click() }
        let review = app.windows["ww.review.window"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let corner = review.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -280, dy: -200)))
        XCTAssertGreaterThanOrEqual(review.frame.width, 720, "Review must preserve its supported native minimum width.")
        XCTAssertGreaterThanOrEqual(review.frame.height, 332, "Review must preserve its supported content and title bar.")
        checkDetails(in: review, app: app, name: "detached-review-details-200-minimum")
    }

    private func checkDetails(in window: XCUIElement, app: XCUIApplication, name: String) {
        let button = window.buttons["ww.review.details"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        // Native focus traversal scrolls the footer action into view when necessary.
        let search = window.textFields["ww.review.search"]
        search.click()
        for _ in 0..<12 {
            if Acceptance.hasKeyboardFocus(button) { break }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(Acceptance.hasKeyboardFocus(button), "Review Details must be keyboard reachable.")
        app.typeKey(.space, modifierFlags: [])
        let content = app.scrollViews["ww.review.details.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5), app.debugDescription)
        let interval = content.popUpButtons["ww.review.details.interval"]
        XCTAssertTrue(interval.exists, "The detail view can browse reviews even when the table viewport is small.")
        XCTAssertEqual(interval.label, "Review interval")
        for text in ["Host", "Um,", "Needs review", "00:00:02.150"] {
            let value = content.staticTexts[text].firstMatch
            XCTAssertTrue(value.exists, "Full critical review value: \(text)")
            for _ in 0..<6 {
                if content.frame.contains(value.frame) { break }
                content.scroll(byDeltaX: 0, deltaY: -80)
            }
            XCTAssertTrue(value.isHittable, "The full value has a visible, non-resizing path.")
            XCTAssertGreaterThanOrEqual(value.frame.width, 20)
            XCTAssertTrue(content.frame.contains(value.frame), "Critical value is not clipped by the detail viewport.")
        }
        record(app, name)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testFillerValidationRetainsDraftAndFocusAcrossAllScopes() {
        let app = launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["ww.settings.window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Transcription"].click()
        checkInvalidWords("ww.settings.fillers", in: app)
        settings.typeKey("w", modifierFlags: .command)
        let review = detachReview(app)
        review.buttons["ww.review.fillerWords"].click()
        app.buttons["ww.show.fillers.customize"].click()
        checkInvalidWords("ww.show.fillers", in: app)
        let scope = app.popUpButtons["ww.review.fillerWords.scope"]
        XCTAssertEqual(scope.label, "Filler-word scope")
        scope.click()
        app.menuItems["Host"].click()
        app.buttons["ww.speaker.fillers.customize"].click()
        checkInvalidWords("ww.speaker.fillers", in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(review.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ww.review.restore.'")).firstMatch.exists,
                       "Invalid settings must not scan, cut or change review judgments.")
    }

    private func checkInvalidWords(_ identifier: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "\(identifier).words").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let initial = field.value as? String
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("you know")
        app.buttons["\(identifier).apply"].click()
        let error = app.staticTexts["\(identifier).error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "you know")
        XCTAssertEqual(field.label, "Filler words, invalid entry")
        XCTAssertTrue(Acceptance.hasKeyboardFocus(field))
        record(app, "\(identifier)-validation", values: [
            "fieldLabel": field.label, "draft": field.value as? String ?? "",
            "visibleError": error.value as? String ?? error.label,
            "voiceOverRunning": XCUIApplication(bundleIdentifier: "com.apple.VoiceOver").state != .notRunning,
            "speechQualification": "Not inferred from this accessibility tree or audit.",
        ])
        field.typeKey("a", modifierFlags: .command)
        field.typeText(initial ?? "")
        XCTAssertTrue(error.waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.label, "Filler words")
        XCTAssertFalse(app.buttons["\(identifier).apply"].isEnabled,
                       "The rejected draft did not replace the stored words.")
    }

    func testHeldPeakRetainsClippingAfterStopAndResetClearsIt() {
        let app = launch()
        defer { app.terminate() }
        let main = app.windows["ww.show.window"]
        let play = main.buttons["alignment.waveforms.transport.play"]
        XCTAssertTrue(wait { play.isEnabled })
        XCUIElement.perform(withKeyModifiers: .option) { app.buttons["ww.mixer.toggle"].click() }
        let mixer = app.windows["ww.mixer.window"]
        let gain = mixer.textFields["ww.mixer.strip.master.gain"]
        XCTAssertTrue(gain.waitForExistence(timeout: 5))
        gain.click()
        gain.typeKey("a", modifierFlags: .command)
        gain.typeText("24")
        gain.typeKey(.return, modifierFlags: [])
        main.click()
        playProductionMix(in: app)
        let peak = mixer.buttons["ww.mixer.strip.master.peak"]
        XCTAssertTrue(wait { (peak.value as? String ?? "").contains("; clipping latched") })
        main.buttons["alignment.waveforms.transport.stop"].click()
        let retained = peak.value as? String ?? ""
        XCTAssertTrue(retained.hasPrefix("Held peak "))
        XCTAssertTrue(retained.contains("dBFS; clipping latched"))
        record(app, "held-peak-after-stop", values: [
            "value": retained,
            "currentMeter": mixer.otherElements["ww.mixer.strip.master.level"].value as? String ?? "",
        ])
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems.matching(NSPredicate(
            format: "identifier == 'makeKeyAndOrderFront:' AND title CONTAINS ' - Mixer'"
        )).firstMatch.click()
        peak.click()
        XCTAssertTrue(wait { peak.value as? String == "No held peak measurement; no clipping latched" })
        record(app, "held-peak-reset")
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
