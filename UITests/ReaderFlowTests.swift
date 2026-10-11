import XCTest

/// End-to-end flows. Books must already be in the app's Documents/Books (see scripts/seed-simulator.sh).
/// Set TEST_RUNNER_SCREENSHOT_DIR to also write PNGs to the host (handy when driving from the CLI).
@MainActor
final class ReaderFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Coordinate-based tests below assume vertical scrolling for PDF/DjVu; horizontal has its own test.
        app.launchArguments += ["-pageTurning", name.contains("Horizontal") ? "horizontal" : "vertical"]
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
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapter '")).firstMatch
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
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapter '")).firstMatch
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
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapter '")).firstMatch
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
    /// They are imported automatically at launch; a manual sync afterwards finds the Inbox empty.
    func testInboxAutoImportsIntoFolders() throws {
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Imported 2 books'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No automatic import")
        snap("inbox-1-auto-imported")
        openFolder("From Inbox")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Inbox Book'")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Sync iCloud Inbox"].tap()
        let alert = app.alerts["Inbox synced"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'The Inbox is empty'")).firstMatch.exists)
        snap("inbox-2-manual-sync-empty")
        alert.buttons["OK"].tap()
    }

    func testCHMOpensWithContents() throws {
        open(bookMatching: "Python 3.10 docs")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 30))
        app.buttons["Contents"].tap()
        let tutorial = app.buttons.matching(NSPredicate(format: "label CONTAINS 'The Python Tutorial'")).firstMatch
        XCTAssertTrue(tutorial.waitForExistence(timeout: 5))
        tutorial.tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Python'")).firstMatch
            .waitForExistence(timeout: 20))
        sleep(2)
        snap("chm-1-tutorial")
    }

    func testWebArchiveOpens() throws {
        open(bookMatching: "Entropy (Wikipedia)")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'thermodynamic'")).firstMatch
            .waitForExistence(timeout: 20), "Web archive text did not render")
        sleep(2)
        snap("webarchive-1")
    }

    func testHorizontalPagesForPDFAndDjVu() throws {
        openFolder("Physics")
        open(bookMatching: "DJVU")
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertEqual(indicator.label, "Page 1 of 3")
        sleep(2)
        snap("horizontal-1-djvu")
        app.swipeLeft()
        sleep(1)
        XCTAssertEqual(indicator.label, "Page 2 of 3", "Swiping left did not turn to the next DjVu page")
        snap("horizontal-2-djvu-page2")
        app.swipeRight()
        sleep(1)
        XCTAssertEqual(indicator.label, "Page 1 of 3")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        sleep(2)
        app.swipeLeft()
        sleep(1)
        XCTAssertEqual(indicator.label, "Page 2 of 3", "Swiping left did not turn to the next PDF page")
        snap("horizontal-3-pdf-page2")

        // Page picker: type a page number.
        indicator.tap()
        let field = app.textFields["Go to page"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("3\n")
        sleep(1)
        // The popover covers the toolbar; close it before reading the counter.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "Page 3 of 3")
    }

    func testBackAfterFollowingLinks() throws {
        // FB2 footnote → Notes chapter → Back.
        openFolder("Fiction")
        open(bookMatching: "Тепло и порядок")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 10))
        app.buttons["Contents"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Глава первая'")).firstMatch.tap()
        let footnote = app.webViews.links["1"]
        XCTAssertTrue(footnote.waitForExistence(timeout: 10), "Footnote link not rendered")
        // Contents navigation itself pushed a position; clear it so we test the link alone.
        if app.buttons["Forget"].waitForExistence(timeout: 2) { app.buttons["Forget"].tap() }
        footnote.tap()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No Back button after following a link")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Во втором начале'")).firstMatch
            .waitForExistence(timeout: 5), "Footnote text not shown")
        snap("back-1-fb2-footnote")
        back.tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Больцман'")).firstMatch
            .waitForExistence(timeout: 5), "Back did not return to the chapter")
        XCTAssertFalse(back.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // PDF internal link (page 1 → 3) → Back.
        openFolder("Physics")
        open(bookMatching: "Linked")
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        sleep(2)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.13)).tap()
        let appeared = back.waitForExistence(timeout: 5)
        sleep(1)
        snap("back-2-pdf-link")
        XCTAssertTrue(appeared, "No Back button after a PDF link")
        XCTAssertEqual(indicator.label, "Page 3 of 3")
        back.tap()
        sleep(1)
        XCTAssertEqual(indicator.label, "Page 1 of 3")
    }

    func testReadLaterFromLongPressedLink() throws {
        open(bookMatching: "Entropy (Wikipedia)")
        let link = app.webViews.links.matching(NSPredicate(format: "label == 'microstates'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), "Link not found")
        link.press(forDuration: 1.2)
        let add = app.buttons["Add to Read Later"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "No link menu")
        snap("readlater-1-menu")
        add.tap()
        XCTAssertTrue(app.staticTexts["Added to Read Later"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Read Later"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS 'microstates'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Entry not listed")
        snap("readlater-2-list")
    }

    func testBookmarksAndSearch() throws {
        // Bookmark page 2 of the DjVu book, then find it from the library-wide view by searching.
        openFolder("Physics")
        open(bookMatching: "DJVU")
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        indicator.tap()
        let field = app.textFields["Go to page"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("2\n")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        // Bookmarks persist (and sync) between runs: start from an unbookmarked page.
        if app.buttons["Remove bookmark"].waitForExistence(timeout: 2) {
            app.buttons["Remove bookmark"].tap()
            XCTAssertTrue(app.buttons["Bookmark this page"].waitForExistence(timeout: 5), "Bookmark was not removed")
        }
        app.buttons["Bookmark this page"].tap()
        XCTAssertTrue(app.buttons["Remove bookmark"].waitForExistence(timeout: 5), "Bookmark icon did not fill")
        snap("bookmarks-1-marked")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Bookmarks"].tap()
        let search = app.searchFields["Search bookmarks and books"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Thermodynamics")
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'p. 2'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Bookmark not found by search")
        snap("bookmarks-2-all")
        entry.tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertEqual(indicator.label, "Page 2 of 3", "Bookmark did not open its page")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // File-name search across folders.
        let librarySearch = app.searchFields["Search all books"]
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5))
        librarySearch.tap()
        librarySearch.typeText("тепло")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Тепло и порядок'")).firstMatch
            .waitForExistence(timeout: 5), "File-name search failed")
        snap("search-1-files")
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

    /// "Chapter 3 of 9, page 34 of 480" → 3
    private func chapterNumber(_ label: String) -> Int {
        Int(label.dropFirst("Chapter ".count).prefix { $0.isNumber }) ?? -1
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
