import AppKit
import WWPersistence
import XCTest

/// Integrated M1 keyboard tasks not covered by the lane suites (accessibility-acceptance T01, T02 undo,
/// T03 persistence, T15, T16, T17, T20, T24), driven with key events plus AX focus checks, with an
/// accessibility audit on each new surface. Synthetic documents only (`wwpersist-probe`, `WW_PROBE`).
///
/// Menu-bar commands without a shortcut use XCUITest's menu API (the keyboard path to the menu bar, ⌃F2,
/// needs Full Keyboard Access, which is a user-manual exit item). Each task records Pass/Fail with its
/// findings into `a11y001-core-tasks.json`; a failed task fails the test at the end.
@MainActor
final class CoreTasksKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!
    private var findings: [String] = []

    private static let autosaveOff = Notification.Name("com.brandonmartinez.wavewrangler.uitest.autosave.off")
    private static let original = "Synthetic Trial Show 1"

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["WW_PROBE"] != nil else {
            throw XCTSkip("WW_PROBE is not set; run scripts/test.sh --ui")
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WaveWranglerCoreTasks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning { app.terminate() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    // MARK: - Tasks

    /// T01 (K01): ⌘N → save panel (location first) → name + folder by keyboard → Create → new show window.
    func testT01CreateShowFromSavePanel() throws {
        try task("T01") {
            launch(["-WWUITestResetStorage", "YES"])
            app.typeKey("n", modifierFlags: .command)
            check(app.buttons["Create"].waitForExistence(timeout: 5), "save panel shown (Create button)")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Keyboard Show")
            try chooseSaveFolder(confirmButton: "Create")
            app.typeKey(.return, modifierFlags: [])
            let file = workDirectory.appending(path: "Keyboard Show.wwshow")
            check(Acceptance.waitFor(timeout: 10) { FileManager.default.fileExists(atPath: file.path) }, "show file created at the chosen location")
            let window = app.windows["ww.library.window"]
            check(window.waitForExistence(timeout: 10), "new show managed in Library")
            check(app.staticTexts["Keyboard Show"].exists, "Library displays the show name")
            let episodes = element("ww.library.episodes")
            check(episodes.waitForExistence(timeout: 5) && value(episodes) == "0 episodes", "Episodes — 0 episodes: \(value(episodes))")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "Saved only after verified create: \(value(status))")
            try audit("T01 new show window")
        }
    }

    /// T02 (K02) undo, T03 (K03/K04) persistence after ⌘S and reopen, T15 (K15) explicit Save with autosave OFF.
    func testT02T03T15EpisodeMetadataExplicitSaveAndReopen() throws {
        let document = try makeDocument("Metadata")
        try task("T02 undo") {
            let window = try launchAndOpen(document, autosave: false)
            EpisodeLibraryNavigation.browseCurrentShow(in: app)
            let episodes = element("ww.library.episodes")
            check(episodes.waitForExistence(timeout: 5), "episode list")
            let before = value(episodes)
            app.typeKey("n", modifierFlags: [.command, .shift])
            let rename = element("ww.show.sidebar.rename")
            check(rename.waitForExistence(timeout: 5), "inline rename focused after New Episode")
            check(isFocused("ww.show.sidebar.rename"), "focus in the rename field")
            app.typeKey(.escape, modifierFlags: [])
            check(value(episodes) != before, "episode added: \(value(episodes))")
            app.typeKey("z", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 3) { self.value(episodes) == before }, "⌘Z removes the new episode: \(value(episodes))")
        }
        app.terminate()
        let metadata = try makeDocument("Metadata T03")
        try task("T03 + T15") {
            let window = try launchAndOpen(metadata, autosave: false, freshStorage: false)
            let document = metadata
            window.typeKey("i", modifierFlags: .command)
            let title = element("ww.inspector.episode.title")
            check(title.waitForExistence(timeout: 5), "⌘I shows the episode inspector")
            check(isFocused("ww.inspector.episode.title"), "⌘I focuses Title")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Keyboard Title")
            app.typeKey("\t", modifierFlags: [])
            check(isFocused("ww.inspector.episode.number"), "Tab reaches Number")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("7\t")
            let status = element("ww.show.saveStatus")
            check(Acceptance.waitFor(timeout: 3) { !self.value(status).hasPrefix("Saved") }, "edits never show Saved before ⌘S: \(value(status))")
            check(diskEpisode(document)?.title != "Keyboard Title", "autosave OFF: nothing written before ⌘S")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.value(status).hasPrefix("Saved") }, "⌘S → Saved: \(value(status))")
            check(diskEpisode(document)?.title == "Keyboard Title" && diskEpisode(document)?.number == 7, "disk has the edits: \(String(describing: diskEpisode(document)))")
            try audit("T03 episode inspector")
            app.typeKey("w", modifierFlags: .command)
            check(!app.sheets.firstMatch.waitForExistence(timeout: 1.5), "saved document closes without a prompt")
            app.open(document)
            let reopened = element("ww.inspector.episode.title")
            window.typeKey("i", modifierFlags: .command)
            check(reopened.waitForExistence(timeout: 10) && value(reopened) == "Keyboard Title", "reopen shows the saved title: \(value(reopened))")
            check(value(element("ww.inspector.episode.number")) == "7", "reopen shows the saved number")
        }
    }

    func testNativeSaveAfterMetadataOnlyPackageChanges() throws {
        let document = try makeDocument("Metadata Only Save")
        try task("native-save-metadata") {
            let window = try launchAndOpen(document, autosave: false)
            for (index, title) in ["First metadata-only save", "Repeated metadata-only save"].enumerated() {
                try editShowTitle(window, title)
                let prior = try ShowStorage.read(document)
                if index == 1 {
                    let replacement = workDirectory.appending(path: "Identical provider replacement.wwshow")
                    try FileManager.default.copyItem(at: document, to: replacement)
                    _ = try FileManager.default.replaceItemAt(document, withItemAt: replacement)
                }
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                                      ofItemAtPath: document.path)
                XCTAssertEqual(try ShowStorage.read(document), prior)
                if index == 0 {
                    XCTAssertTrue(app.chooseMenu(["File", "Save"]))
                } else {
                    app.typeKey("s", modifierFlags: .command)
                }
                XCTAssertTrue(Acceptance.waitFor(timeout: 10) { self.diskTitle(document) == title },
                              "Native Save must not stop at an external-change warning for identical contents")
                XCTAssertFalse(app.sheets.firstMatch.exists)
            }
            try editShowTitle(window, "Saved from native Close")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                                  ofItemAtPath: document.path)
            window.typeKey("w", modifierFlags: [.command, .shift])
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.buttons["Save"].waitForExistence(timeout: 5))
            sheet.buttons["Save"].click()
            XCTAssertTrue(Acceptance.waitFor(timeout: 10) { !window.exists },
                          "the original native Close callback completes after the verified save")
            XCTAssertEqual(diskTitle(document), "Saved from native Close")
        }
    }

    func testAutomaticSaveAfterMetadataOnlyPackageChanges() throws {
        let document = try makeDocument("Automatic Metadata Save")
        try task("automatic-save-metadata") {
            let window = try launchAndOpen(document, autosave: true,
                extraArguments: ["-WWUITestAutosaveDelaySeconds", "2"])
            window.typeKey("i", modifierFlags: .command)
            let title = element("ww.inspector.episode.title")
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            for index in 0..<3 {
                let expected = "Automatically saved metadata edit \(index)"
                let prior = try ShowStorage.read(document)
                if index == 1 {
                    let replacement = workDirectory.appending(path: "Identical automatic replacement.wwshow")
                    try FileManager.default.copyItem(at: document, to: replacement)
                    _ = try FileManager.default.replaceItemAt(document, withItemAt: replacement)
                }
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                                      ofItemAtPath: document.path)
                XCTAssertEqual(try ShowStorage.read(document), prior)
                title.click()
                title.typeKey("a", modifierFlags: .command)
                title.typeText(expected)
                title.typeKey("\t", modifierFlags: [])
                if index == 2 { app.typeKey("s", modifierFlags: .command) }
                let saved = Acceptance.waitFor(timeout: 12) { self.diskEpisode(document)?.title == expected }
                Acceptance.record(self, "Automatic save \(index): \(nativeSheetDescription())")
                XCTAssertTrue(saved, "Autosave ON must save metadata-only changes without an overwrite prompt")
                guard saved else { return }
                XCTAssertFalse(app.sheets.firstMatch.exists)
                XCTAssertTrue(Acceptance.waitFor(timeout: 5) {
                    self.value(self.element("ww.show.saveStatus")).hasPrefix("Saved")
                }, "automatic publication is verified before reporting Saved")
            }
            app.typeKey("w", modifierFlags: [.command, .shift])
            XCTAssertTrue(Acceptance.waitFor(timeout: 10) { !window.exists })
            XCTAssertFalse(app.sheets.firstMatch.exists, "a verified autosaved show closes without an overwrite prompt")
        }
    }

    func testNativeSaveDoesNotRecreateADeletedPackage() throws {
        try checkDeletedPackageSave(automatic: false)
    }

    func testNativeSaveDoesNotRecreateADeletedPackageWithAutosaveEnabled() throws {
        try checkDeletedPackageSave(automatic: true)
    }

    private func checkDeletedPackageSave(automatic: Bool) throws {
        let document = try makeDocument("Deleted Native Save")
        try task("native-save-deleted") {
            let window = try launchAndOpen(document, autosave: automatic,
                extraArguments: ["-WWUITestAutosaveDelaySeconds", "30"])
            try editShowTitle(window, "Keep my deleted-file draft")
            try FileManager.default.removeItem(at: document)
            app.typeKey("s", modifierFlags: .command)
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the deleted destination is reported")
            if sheet.buttons["Save"].exists { sheet.buttons["Save"].click() }
            Acceptance.record(self, "Deleted destination refusal: \(nativeSheetDescription())")
            let conflict = app.sheets.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] 'could not be saved' OR value CONTAINS[c] 'could not be saved' OR label CONTAINS[c] 'no such file' OR value CONTAINS[c] 'no such file'")).firstMatch
            XCTAssertTrue(conflict.waitForExistence(timeout: 10), "missing saved bytes cannot be silently replaced")
            XCTAssertFalse(app.sheets.buttons["Save"].exists, "a missing base has no force-overwrite choice")
            XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(window.exists, "the unsaved draft stays open")
        }
    }

    /// T16 (K16): another writer changes the contents without changing the timestamp; native Save
    /// refuses the exact-base conflict, reports Not saved, and Close offers a copy rather than a plain Save.
    func testT16ConflictNeverOverwrites() throws {
        let document = try makeDocument("Conflict")
        try task("T16") {
            let window = try launchAndOpen(document, autosave: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: document.path)
            let originalDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
            try probe(["save", "--file", document.path, "--title", "Other Writer"])
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: document.path)
            check(diskTitle(document) == "Other Writer", "second writer published")
            let otherVersion = try ShowStorage.read(document)
            let otherModel = try ShowPackageCoder().decode(otherVersion).payload
            try editShowTitle(window, "Mine")
            let status = element("ww.show.saveStatus")
            for attempt in 1...2 {
                app.typeKey("s", modifierFlags: .command)
                check(app.sheets.firstMatch.waitForExistence(timeout: 10),
                      "Save attempt \(attempt) presents its conflict refusal: \(nativeSheetDescription())")
                let sheet = app.sheets.firstMatch
                Acceptance.record(self, "T16 sheet: \(sheet.staticTexts.allElementsBoundByIndex.map(\.value)) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
                try audit("T16 exact-base refusal")
                let refusal = sheet.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS[c] 'Expected r' OR value CONTAINS[c] 'Expected r'")).firstMatch
                check(refusal.exists && !sheet.buttons["Save"].exists,
                      "the actual byte conflict is refused without a force-overwrite choice")
                app.typeKey(.return, modifierFlags: [])
                check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists },
                      "refusal alert dismissed with Return")
                check(window.exists, "refusal keeps the user's document open")
                check(try ShowStorage.read(document) == otherVersion, "retry never overwrites the competing version")
            }
            check(diskTitle(document) == "Other Writer", "the other version is not overwritten")
            Acceptance.record(self, "T16 save status after refusal: label \(status.label) value \(value(status)) window title \(window.title)")
            check(Acceptance.waitFor(timeout: 5) {
                self.value(status).hasPrefix("Not saved") && self.value(status).contains("Couldn't save:")
            }, "native refused save is explicitly Not saved/Couldn't save: \(value(status))")
            app.typeKey("w", modifierFlags: [.command, .shift])
            if app.sheets.firstMatch.waitForExistence(timeout: 5) {
                let sheet = app.sheets.firstMatch
                Acceptance.record(self, "T16 close sheet: \(sheet.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) buttons \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
                check(!sheet.buttons["Save"].exists, "no plain Save while conflicted (Design D6)")
                if sheet.buttons["Save"].exists {
                    // Exercise it: a plain Save from the close sheet must still never overwrite the other version.
                    let before = nativeSheetDescription()
                    sheet.buttons["Save"].click()
                    waitForSheetTransition(from: before, window: window)
                    for _ in 0..<3 where app.sheets.firstMatch.exists {
                        let next = app.sheets.firstMatch
                        Acceptance.record(self, "T16 after close-sheet Save: \(next.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) buttons \(next.buttons.allElementsBoundByIndex.map(\.title))")
                        let before = nativeSheetDescription()
                        if next.buttons["Save"].exists { next.buttons["Save"].click() } else if next.buttons["OK"].exists { app.typeKey(.return, modifierFlags: []) } else { app.typeKey(.escape, modifierFlags: []) }
                        waitForSheetTransition(from: before, window: window)
                    }
                    Acceptance.record(self, "T16 after close-sheet Save: window exists \(window.exists), status \(window.exists ? value(status) : "closed"), disk \(diskTitle(document) ?? "nil")")
                    check(window.exists, "the conflicted window isn't closed by a refused save (work kept)")
                } else {
                    app.typeKey(.escape, modifierFlags: [])
                    check(Acceptance.waitFor(timeout: 5) { !self.app.sheets.firstMatch.exists } && window.exists, "Esc (Cancel) dismisses the close sheet and keeps the window open")
                    check(try ShowStorage.read(document) == otherVersion, "close Cancel does not publish")
                }
            } else {
                check(false, "Close while conflicted asks how to keep the changes")
            }
            // The way forward the refusal offers ("Save them as a new document"): Save As… (⌥⇧⌘S) by keyboard.
            if window.exists {
                let copy = workDirectory.appending(path: "Conflict Mine.wwshow")
                window.typeKey("s", modifierFlags: [.command, .shift, .option])
                let panelShown = app.sheets.firstMatch.waitForExistence(timeout: 5)
                check(panelShown, "Save As… panel shown from the conflicted window (⌥⇧⌘S)")
                if panelShown {
                    app.typeKey("a", modifierFlags: .command)
                    app.typeText("Conflict Mine")
                    try chooseSaveFolder(confirmButton: "Save")
                    app.typeKey(.return, modifierFlags: [])
                    check(Acceptance.waitFor(timeout: 10) { self.diskTitle(copy) == "Mine" }, "Save As from conflict wrote the user's edits to a new document: \(diskTitle(copy) ?? "nil")")
                    let status = element("ww.show.saveStatus")
                    Acceptance.record(self, "T16 after Save As: window title \(window.title), status \(value(status)), copy \(diskTitle(copy) ?? "nil"), other \(diskTitle(document) ?? "nil")")
                }
            }
            let retained = try ShowStorage.read(document)
            check(retained == otherVersion, "other writer's complete stored bytes remain unchanged")
            check(try ShowPackageCoder().decode(retained).payload == otherModel,
                  "other writer's complete model remains unchanged after refusal, Cancel and Save As")
        }
    }

    /// T17 (K17): the newest file is damaged; the app opens the last complete version from its device-local
    /// recovery store and says so in a persistent message bar.
    func testT17RecoverPriorWork() throws {
        let document = try makeDocument("Recover")
        try task("T17") {
            let window = try launchAndOpen(document, autosave: false)
            try editShowTitle(window, "Complete Version")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.diskTitle(document) == "Complete Version" }, "complete version saved (prior retained)")
            try editShowTitle(window, "Newest Version")
            app.typeKey("s", modifierFlags: .command)
            check(Acceptance.waitFor(timeout: 10) { self.diskTitle(document) == "Newest Version" }, "newest version saved")
            app.terminate()
            // Simulate an incomplete newest save by truncating its manifest.
            let content = try ShowStorage.contentURL(document)
            let data = try Data(contentsOf: content)
            try data.prefix(data.count / 2).write(to: content)
            let reopened = try openOptionally(document, autosave: false)
            Thread.sleep(forTimeInterval: 2)
            let texts = app.descendants(matching: .staticText).allElementsBoundByIndex.prefix(40).map { "\($0.value ?? $0.label)" }
            Acceptance.record(self, "T17 after reopen: windows \(app.windows.allElementsBoundByIndex.map(\.title)) texts \(texts)")
            let bar = element("ww.show.messageBar")
            _ = reopened
            let offer = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
            check(offer.exists || bar.exists, "a recovery offer or message bar appears")
            if offer.exists {
                Acceptance.record(self, "T17 offer buttons: \(offer.buttons.allElementsBoundByIndex.map(\.title))")
                try audit("T17 recovery offer")
                let open = offer.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'Open' OR title CONTAINS[c] 'Copy' OR title CONTAINS[c] 'Earlier'")).firstMatch
                check(open.exists, "an action opens the kept complete version")
                if open.exists { open.click() }
                let copy = app.windows.matching(identifier: "ww.show.window").firstMatch
                check(copy.waitForExistence(timeout: 10), "the complete version opens")
                let title = copy.textFields["Show title"]
                let info = copy.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
                check(info.waitForExistence(timeout: 5), "Show Info is available on the recovered copy")
                if info.exists { info.click() }
                check(title.waitForExistence(timeout: 5), "Show title appears after selecting Show Info")
                check(title.waitForExistence(timeout: 5) && title.value as? String == "Complete Version", "opened the last complete version: \(title.value ?? "nil")")
                Acceptance.record(self, "T17 opened window title: \(copy.title)")
            }
            check(data.prefix(data.count / 2) == (try? Data(contentsOf: content)), "the damaged manifest is left unchanged")
        }
    }

    /// T20 (K19): a show written by a newer WaveWrangler is refused for editing and saving with a reason.
    func testT20UnknownNewerRefusal() throws {
        let document = try makeDocument("Newer")
        let content = try ShowStorage.contentURL(document)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: content)) as! [String: Any]
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: content)
        let bytes = try Data(contentsOf: content)
        try task("T20") {
            _ = try openOptionally(document, autosave: true, freshStorage: true)
            Thread.sleep(forTimeInterval: 2)
            let texts = app.descendants(matching: .staticText).allElementsBoundByIndex.prefix(40).map { "\($0.value ?? $0.label)" }
            Acceptance.record(self, "T20 after open: windows \(app.windows.allElementsBoundByIndex.map(\.title)) texts \(texts)")
            let reason = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS[c] 'newer' OR label CONTAINS[c] 'newer'")).firstMatch
            check(reason.waitForExistence(timeout: 5), "refusal names the newer-version reason")
            check(app.windows.matching(identifier: "ww.show.window").count == 0, "no editable window opens")
            if app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists { try audit("T20 refusal") }
            app.typeKey(.escape, modifierFlags: [])
            check((try? Data(contentsOf: content)) == bytes, "manifest bytes unchanged")
        }
    }

    /// T24 (K22): two windows on one show share the document; an edit in one is undone from the other.
    func testT24TwoWindowsSharedUndo() throws {
        let document = try makeDocument("Windows")
        try task("T24") {
            let window = try launchAndOpen(document, autosave: false, extraArguments: ["-WWUITestOffsetNewWindows", "YES"])
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'New Window'")).firstMatch.click()
            let windows = app.windows.matching(identifier: "ww.show.window")
            check(windows.element(boundBy: 1).waitForExistence(timeout: 5), "second window")
            let first = windows.element(boundBy: 0)
            let second = windows.element(boundBy: 1)
            try editShowTitle(first, "Shared Edit")

            @MainActor func recordUndoState(_ moment: String) {
                app.menuBars.menuBarItems["Edit"].click()
                let undo = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo '")).firstMatch
                let undoExists = undo.waitForExistence(timeout: 3)
                let key = windows.allElementsBoundByIndex.first {
                    ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true
                }?.title ?? "none"
                Acceptance.writeEvidence("t24-\(moment)", [
                    "keyWindow": key,
                    "undoTitle": undoExists ? undo.title : "missing",
                    "undoEnabled": undoExists && undo.isEnabled,
                    "firstTitle": first.title,
                    "secondTitle": second.title,
                    "firstFrame": "\(first.frame)",
                    "secondFrame": "\(second.frame)",
                    "framesDistinct": first.frame != second.frame,
                ], test: self)
                if moment == "before-command-z" {
                    check(undoExists && undo.isEnabled, "Undo is enabled before ⌘Z")
                }
                app.typeKey(.escape, modifierFlags: [])
            }

            recordUndoState("before-command-z")
            second.click()
            app.typeKey("z", modifierFlags: .command)
            recordUndoState("after-command-z")
            let showInfo = window.textFields["Show title"]
            check(Acceptance.waitFor(timeout: 3) { showInfo.value as? String == Self.original }, "undo from the other window reverts the shared edit")
        }
    }

    // MARK: - Recording

    private var results: [[String: Any]] = []

    private func task(_ id: String, _ body: () throws -> Void) throws {
        findings = []
        do { try body() } catch { findings.append("threw \(error)") }
        let passed = findings.isEmpty
        Acceptance.record(self, "A11Y-001 \(id): \(passed ? "PASS" : "FAIL \(findings)")")
        results.append(["task": id, "passed": passed, "findings": findings])
        Acceptance.writeEvidence("a11y001-\(id)", ["task": id, "passed": passed, "findings": findings, "revision": Acceptance.revision()], test: self)
        for finding in findings { XCTFail("\(id): \(finding)") }
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { findings.append(message) }
    }

    // MARK: - Helpers

    private func chooseSaveFolder(confirmButton: String) throws {
        app.typeKey("g", modifierFlags: [.command, .shift])
        var pathField: XCUIElement?
        let focused = Acceptance.waitFor(timeout: 5) {
            pathField = self.app.textFields.allElementsBoundByIndex.first {
                ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true
                    && self.value($0).hasPrefix("/")
            }
            return pathField != nil
        }
        check(focused, "Go to Folder has a focused path field")
        guard let pathField else { throw NSError(domain: "CoreTasks", code: 3) }
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(workDirectory.path)
        check(Acceptance.waitFor(timeout: 5) { self.value(pathField) == self.workDirectory.path },
              "Go to Folder contains the requested path: \(value(pathField))")
        app.typeKey(.return, modifierFlags: [])
        check(Acceptance.waitFor(timeout: 5) {
            self.app.buttons[confirmButton].isHittable
        }, "\(confirmButton) is ready after Go to Folder closes: \(nativeSheetDescription())")
    }

    private func nativeSheetDescription() -> String {
        let sheet = app.sheets.firstMatch
        guard sheet.exists else { return "no sheet" }
        return "\(sheet.staticTexts.allElementsBoundByIndex.map { $0.value ?? $0.label }) \(sheet.buttons.allElementsBoundByIndex.map(\.title))"
    }

    private func waitForSheetTransition(from previous: String, window: XCUIElement) {
        check(Acceptance.waitFor(timeout: 5) {
            !window.exists || self.nativeSheetDescription() != previous
        }, "native response changed after the action: \(nativeSheetDescription())")
    }

    private func launch(_ arguments: [String], opening document: URL? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-WWUITestHooks", "YES", "-WWUITestResetPreferences", "YES",
                               "-WWUITestCenterWindows", "YES"] + arguments
        // One launch only: see `XCUIApplication.launchOnce(opening:)`.
        if let document { app.launchOnce(opening: document) } else { app.launch(); app.activate() }
    }

    @discardableResult
    /// `freshStorage` deletes the isolated UI-test storage (library, recovery, edit checkpoints) left by earlier
    /// suites, e.g. the DUR-026 checkpoint scenario, whose restore offer would otherwise cover the window.
    private func openOptionally(_ document: URL, autosave: Bool, expectWindow: Bool = false, freshStorage: Bool = false,
                                extraArguments: [String] = []) throws -> XCUIElement? {
        launch(["-WWUITestAutosave", autosave ? "ON" : "OFF"] + (freshStorage ? ["-WWUITestResetStorage", "YES"] : []) + extraArguments, opening: document)
        let window = app.windows.matching(identifier: "ww.show.window").firstMatch
        guard window.waitForExistence(timeout: 10) else {
            if expectWindow { throw NSError(domain: "CoreTasks", code: 1, userInfo: [NSLocalizedDescriptionKey: "window did not open"]) }
            return nil
        }
        if !autosave {
            DistributedNotificationCenter.default().postNotificationName(Self.autosaveOff, object: nil, userInfo: nil, deliverImmediately: true)
            Thread.sleep(forTimeInterval: 0.3)
        }
        return window
    }

    private func launchAndOpen(_ document: URL, autosave: Bool, freshStorage: Bool = true,
                               extraArguments: [String] = []) throws -> XCUIElement {
        guard let window = try openOptionally(document, autosave: autosave, expectWindow: true, freshStorage: freshStorage,
                                              extraArguments: extraArguments) else {
            throw NSError(domain: "CoreTasks", code: 1)
        }
        let update = window.buttons["ww.formatUpdate.update"]
        let status = window.buttons["ww.show.saveStatus"]
        guard Acceptance.waitFor(timeout: 5, {
            status.exists && (update.exists || !self.value(status).hasPrefix("Read-only"))
        }) else {
            throw NSError(domain: "CoreTasks", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Generated fixture is not editable: \(nativeSheetDescription())"
            ])
        }
        if update.exists {
            update.click()
            guard Acceptance.waitFor(timeout: 10, {
                !update.exists && !self.value(status).hasPrefix("Read-only")
            }) else {
                throw NSError(domain: "CoreTasks", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Generated fixture update did not finish: \(nativeSheetDescription())"
                ])
            }
        }
        return window
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "\(element.value ?? "")" }

    private func isFocused(_ identifier: String) -> Bool {
        let target = element(identifier)
        return target.exists && (target.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
    }

    private func editShowTitle(_ window: XCUIElement, _ title: String) throws {
        EpisodeLibraryNavigation.browseCurrentShow(in: app)
        let library = app.windows["ww.library.window"]
        let showInfo = library.descendants(matching: .any).matching(identifier: "ww.show.sidebar.showInfo").firstMatch
        guard showInfo.waitForExistence(timeout: 5) else { throw NSError(domain: "CoreTasks", code: 2) }
        showInfo.click()
        let field = library.textFields["Show title"]
        guard field.waitForExistence(timeout: 5) else { throw NSError(domain: "CoreTasks", code: 2) }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        field.typeKey(.return, modifierFlags: [])
        let episodeTitle = window.title.components(separatedBy: " \u{2013} ").first ?? window.title
        app.menuBars.menuBarItems["Window"].click()
        let editor = app.menuBars.menuItems.matching(NSPredicate(
            format: "title BEGINSWITH %@ OR label BEGINSWITH %@", episodeTitle, episodeTitle
        )).firstMatch
        guard editor.exists else {
            throw NSError(domain: "CoreTasks", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Window menu is missing \(episodeTitle)"
            ])
        }
        editor.click()
    }

    private func audit(_ surface: String) throws {
        let unwaived = try AcceptanceAudit.run(app, surface: surface, test: self)
        for finding in unwaived { findings.append("AUDIT \(finding)") }
    }

    @discardableResult
    private func probe(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WW_PROBE"]!)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeDocument(_ name: String) throws -> URL {
        let url = workDirectory.appending(path: "\(name).wwshow")
        guard try probe(["create", "--file", url.path, "--seed", "1"]) == 0, diskTitle(url) == Self.original else {
            throw NSError(domain: "CoreTasks", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture creation failed"])
        }
        return url
    }

    private func payload(_ url: URL) -> [String: Any]? {
        guard let object = try? ShowStorage.envelope(url) else { return nil }
        return object["payload"] as? [String: Any]
    }

    private func diskTitle(_ url: URL) -> String? {
        (payload(url)?["show"] as? [String: Any])?["title"] as? String
    }

    private func diskEpisode(_ url: URL) -> (title: String?, number: Int?)? {
        guard let first = (payload(url)?["episodes"] as? [[String: Any]])?.first else { return nil }
        return (first["title"] as? String, first["number"] as? Int)
    }
}
