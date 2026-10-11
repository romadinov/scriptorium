import XCTest

/// End-to-end flows. Books must already be in the app's Documents/Books (see scripts/seed-simulator.sh).
/// Set TEST_RUNNER_SCREENSHOT_DIR to also write PNGs to the host (handy when driving from the CLI).
@MainActor
final class ReaderFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testDjVuLiveTextDefine() throws {
        openFolder("Physics")
        open(bookMatching: "DJVU")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(5) // let the page render and Live Text analysis finish
        snap("djvu-1-open")

        // Long-press a word in the first paragraph to start a Live Text selection.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.17)).press(forDuration: 1.2)
        snap("djvu-2-selected")

        let define = app.buttons["Define"]
        XCTAssertTrue(define.waitForExistence(timeout: 5), "Selection bar did not appear")
        define.tap()
        waitForAnswer()
        snap("djvu-3-define")
    }

    func testPDFSelectAndExplain() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        snap("pdf-1-open")

        // Long-press selects a word in PDFView.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.235)).press(forDuration: 1.0)
        snap("pdf-2-selected")
        let explain = app.buttons["Define"].exists ? app.buttons["Define"] : app.buttons["Explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5), "Selection bar did not appear")
        explain.tap()
        waitForAnswer()
        snap("pdf-3-answer")
    }

    func testScannedPDFOpensInLiveTextMode() throws {
        open(bookMatching: "Scanned")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(3)
        app.buttons["Assistant"].tap()
        let summarize = app.buttons["Summarize page"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 5))
        summarize.tap()
        waitForAnswer()
        snap("scanned-summary")
    }

    func testEPUBChaptersSelectionAndAssistant() throws {
        snap("library-root")
        openFolder("Fiction")
        snap("library-fiction")
        open(bookMatching: "Pride and Prejudice")
        XCTAssertTrue(app.buttons["Next chapter"].waitForExistence(timeout: 15))
        // Wait until any web content (text, link or image) is in the accessibility tree.
        let content = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@", [XCUIElement.ElementType.staticText.rawValue,
                                                                 XCUIElement.ElementType.link.rawValue,
                                                                 XCUIElement.ElementType.image.rawValue])).firstMatch
        let appeared = content.waitForExistence(timeout: 20)
        snap("epub-1-open")
        XCTAssertTrue(appeared, "Chapter content never appeared")
        // The book reopens where it was left, so compare chapter numbers rather than assume chapter 1.
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ch. '")).firstMatch
        let before = chapterNumber(indicator.label)
        app.buttons["Next chapter"].tap()
        let advanced = NSPredicate { _, _ in self.chapterNumber(indicator.label) == before + 1 }
        wait(for: [expectation(for: advanced, evaluatedWith: nil)], timeout: 5)
        let text = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Bennet'")).firstMatch
        let shown = text.waitForExistence(timeout: 20)
        snap("epub-2-next-chapter")
        XCTAssertTrue(shown, "Next chapter text never appeared")

        // Long-press a word inside a paragraph (a fixed coordinate may land on an illustration).
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.0)
        let explainOrDefine = app.buttons["Define"].waitForExistence(timeout: 5) ? app.buttons["Define"] : app.buttons["Explain"]
        XCTAssertTrue(explainOrDefine.exists, "Selection bar did not appear")
        snap("epub-3-selected")
        explainOrDefine.tap()
        waitForAnswer()
        snap("epub-4-answer")
    }

    func testFB2OpensWithContents() throws {
        openFolder("Fiction")
        open(bookMatching: "Тепло и порядок")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 10))
        app.buttons["Contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Глава вторая'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        snap("fb2-1-contents")
        chapter.tap()
        sleep(2)
        snap("fb2-2-chapter")
    }

    func testEPUBPagesSwipeAcrossChaptersAndHighlightPersists() throws {
        openFolder("Fiction")
        open(bookMatching: "Тепло и порядок")   // small FB2: 4 chapters, quick to cross boundaries
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ch. '")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 15))
        sleep(2)
        snap("pages-1-open")
        let startChapter = chapterNumber(indicator.label)

        // Swipe left until the chapter number changes — chapters must flow without a reload.
        var swipes = 0
        while chapterNumber(indicator.label) == startChapter && swipes < 8 {
            app.webViews.firstMatch.swipeLeft()
            swipes += 1
            sleep(1)
        }
        snap("pages-2-after-swipes")
        XCTAssertEqual(chapterNumber(indicator.label), startChapter + 1, "Swiping did not move into the next chapter")

        // Highlight a word on the visible page. (Querying an element would make XCUITest scroll to the
        // first match, which may be in the previous chapter still loaded off-screen.)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.185)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Highlight"].waitForExistence(timeout: 5), "Selection bar did not appear")
        app.buttons["Highlight"].tap()
        sleep(2)
        snap("pages-3-highlighted")

        app.buttons["Highlights"].tap()
        let entry = app.popovers.buttons.firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Highlight not listed")
        snap("pages-4-list")
        app.tap() // dismiss popover

        // Reopen the book: position and highlight must survive.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        open(bookMatching: "Тепло и порядок")
        XCTAssertTrue(indicator.waitForExistence(timeout: 15))
        sleep(2)
        XCTAssertEqual(chapterNumber(indicator.label), startChapter + 1, "Reading position was not restored")
        app.buttons["Highlights"].tap()
        XCTAssertTrue(app.popovers.buttons.firstMatch.waitForExistence(timeout: 5), "Highlight did not persist")
        snap("pages-5-reopened")
    }

    func testScrollLayout() throws {
        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice")
        XCTAssertTrue(app.buttons["Reading options"].waitForExistence(timeout: 15))
        app.buttons["Reading options"].tap()
        app.buttons["Scroll"].tap()
        sleep(3)
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ch. '")).firstMatch
        let start = chapterNumber(indicator.label)
        for _ in 0..<6 { app.webViews.firstMatch.swipeUp(velocity: .fast) }
        sleep(2)
        snap("scroll-1")
        XCTAssertGreaterThanOrEqual(chapterNumber(indicator.label), start)
        // Restore the default for other tests.
        app.buttons["Reading options"].tap()
        app.buttons["Pages (swipe)"].tap()
    }

    func testPDFAndDjVuHighlights() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.235)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Highlight"].waitForExistence(timeout: 5))
        app.buttons["Highlight"].tap()
        sleep(1)
        snap("highlight-pdf")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        open(bookMatching: "DJVU")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(5)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.17)).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Highlight"].waitForExistence(timeout: 5))
        app.buttons["Highlight"].tap()
        sleep(3)
        snap("highlight-djvu")
        app.buttons["Highlights"].tap()
        XCTAssertTrue(app.popovers.buttons.firstMatch.waitForExistence(timeout: 5), "DjVu highlight not saved")
    }

    /// scripts/seed-simulator.sh drops books into the (local fallback) Inbox, including a new folder.
    func testInboxSyncImportsIntoFolders() throws {
        let sync = app.buttons["Sync iCloud Inbox"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10))
        sync.tap()
        let alert = app.alerts["Inbox synced"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "No sync result")
        snap("inbox-1-result")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 books imported'")).firstMatch.exists)
        alert.buttons["OK"].tap()
        openFolder("From Inbox")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Inbox Book'")).firstMatch.waitForExistence(timeout: 5))
        snap("inbox-2-folder")
    }

    /// Opens Wi-Fi Transfer and holds it open; scripts/transfer-smoke.sh uploads meanwhile.
    func testWiFiTransferScreen() throws {
        app.buttons["Wi-Fi Transfer"].firstMatch.tap()
        let address = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'http://'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Server did not start")
        snap("transfer-1-running")
        sleep(UInt32(ProcessInfo.processInfo.environment["TRANSFER_HOLD"] ?? "2") ?? 2)
        app.buttons["Done"].tap()
        sleep(1)
        snap("transfer-2-library-after")
    }

    // MARK: Helpers

    /// "Ch. 3 / 9" → 3
    private func chapterNumber(_ label: String) -> Int {
        Int(label.dropFirst(4).prefix { $0.isNumber }) ?? -1
    }

    private func openFolder(_ name: String) {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "No folder \(name)")
        folder.tap()
    }

    private func open(bookMatching label: String) {
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), "No book matching \(label)")
        book.tap()
    }

    /// Waits until streaming stops (the Stop button disappears) and something was answered.
    private func waitForAnswer(timeout: TimeInterval = 120) {
        let stop = app.buttons["Stop"]
        _ = stop.waitForExistence(timeout: 5)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        wait(for: [gone], timeout: timeout)
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
