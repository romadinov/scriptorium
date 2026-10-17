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
        app.launchArguments += ["-pageTurning", name.contains("Horizontal") || name.contains("IPhone") ? "horizontal" : "vertical"]
        app.launchArguments += ["-deviceID", "sim-ipad"]          // matches scripts/seed-simulator.sh transfers
        // Tests start in the library, not in the book a previous test left open.
        if !name.contains("Reopens") { app.launchArguments += ["-lastOpenBook", ""] }
        // Page labels are matched exactly; the time-left estimate is only shown in its own test.
        if !name.contains("TimeLeft") { app.launchArguments += ["-showTimeLeft", "NO"] }
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

        let close = app.buttons["assistant.close"]
        XCTAssertTrue(close.exists, "Assistant has no close button")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Assistant did not close")
        snap("pdf-4-closed")
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

        // Long-press a word inside a visible paragraph (a fixed coordinate may land on an illustration).
        let paragraphs = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Bennet'"))
        let window = app.windows.firstMatch.frame
        let paragraph = (0..<min(paragraphs.count, 12)).map { paragraphs.element(boundBy: $0) }
            .first { $0.isHittable && $0.frame.height > 40 && window.contains($0.frame) } ?? text
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.0)
        let explainOrDefine = app.buttons["Define"].waitForExistence(timeout: 5) ? app.buttons["Define"] : app.buttons["Explain"]
        if !explainOrDefine.exists { snap("epub-3-no-bar") }
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

    func testAnnotationsWithTextAndDrawing() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        // Page notes persist between runs: start from a page without one.
        if app.buttons["Remove bookmark"].waitForExistence(timeout: 2) {
            app.buttons["Remove bookmark"].tap()
            let confirm = app.buttons["Remove Bookmark and Note"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            XCTAssertTrue(app.buttons["Bookmark this page"].waitForExistence(timeout: 5))
        }

        // 1. Text note on a selection.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.235)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Note"].waitForExistence(timeout: 5), "Selection bar has no Note button")
        app.buttons["Note"].tap()
        let text = app.textViews["annotation.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Note editor did not open")
        text.tap()
        text.typeText("Entropy never decreases")
        snap("annotation-1-text")
        app.buttons["Save"].tap()
        sleep(1)
        app.buttons["Highlights"].tap()
        let noted = app.popovers.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Entropy never decreases'")).firstMatch
        XCTAssertTrue(noted.waitForExistence(timeout: 5), "Note not shown under the highlight")
        snap("annotation-2-list")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()   // dismiss popover
        sleep(1)

        // 2. Drawing on the page.
        app.buttons["Page Note"].tap()
        XCTAssertTrue(app.buttons["Drawing"].waitForExistence(timeout: 5), "Page note editor did not open")
        app.buttons["Drawing"].tap()
        let canvas = app.otherElements["annotation.canvas"].exists ? app.otherElements["annotation.canvas"]
                                                                    : app.scrollViews["annotation.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "No drawing canvas")
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)))
        snap("annotation-3-drawing")
        app.buttons["Save"].tap()
        let pill = app.buttons["pageNote.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Page shows no note marker")
        XCTAssertTrue(app.buttons["Remove bookmark"].exists, "Page note did not bookmark the page")
        snap("annotation-4-pill")

        // 3. Reopen: the drawing loads back.
        pill.tap()
        sleep(3)
        snap("annotation-5-reopened")
        XCTAssertTrue(app.buttons["Clear Drawing"].waitForExistence(timeout: 10), "Saved drawing did not load")
        app.buttons["Cancel"].tap()

        // 4. Removing the bookmark asks first, because the note goes with it.
        app.buttons["Remove bookmark"].tap()
        let confirm = app.buttons["Remove Bookmark and Note"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation before deleting a page note")
        confirm.tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 5))
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
        // Books reopen where they were left (another test may have moved it): start from page 1.
        if indicator.label != "Page 1 of 3" {
            indicator.tap()
            let go = app.textFields["Go to page"]
            XCTAssertTrue(go.waitForExistence(timeout: 5))
            go.tap()
            go.typeText("1\n")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }
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

    func testPDFLinkLongPressAddsToReadLater() throws {
        openFolder("Physics")
        open(bookMatching: "Linked")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        snap("pdflink-0-page")
        // Link annotation ("Scriptorium on GitHub").
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.236)).press(forDuration: 1.2)
        let add = app.buttons["Add to Read Later"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "No menu on a PDF link annotation")
        snap("pdflink-1-menu")
        add.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label IN {'Added to Read Later', 'Already in Read Later'}")).firstMatch
            .waitForExistence(timeout: 5))
        // URL written as plain text.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.28)).press(forDuration: 1.2)
        XCTAssertTrue(add.waitForExistence(timeout: 5), "No menu on a plain-text URL")
        snap("pdflink-2-plain-url")
        add.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Read Later"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Scriptorium on GitHub'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'python.org'")).firstMatch.exists)
        snap("pdflink-3-list")
    }

    /// iPhone layout: library list, More menus, reading EPUB in pages, PDF left-to-right, assistant sheet.
    func testIPhoneLayout() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        snap("iphone-1-library")
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Wi-Fi Transfer"].waitForExistence(timeout: 3))
        snap("iphone-2-library-menu")
        app.buttons["Bookmarks"].tap()
        XCTAssertTrue(app.navigationBars["Bookmarks & Page Notes"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice")
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 15))
        sleep(3)
        snap("iphone-3-epub")
        app.webViews.firstMatch.swipeLeft()
        sleep(1)
        snap("iphone-4-epub-next-page")
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Highlights & Notes"].waitForExistence(timeout: 3))
        snap("iphone-5-reader-menu")
        app.buttons["Highlights & Notes"].tap()
        XCTAssertTrue(app.buttons["Bookmarks"].waitForExistence(timeout: 5), "Contents/Bookmarks/Highlights panel did not open")
        app.swipeDown(velocity: .fast)
        sleep(1)
        app.buttons["Assistant"].tap()
        sleep(2)
        snap("iphone-6-assistant-sheet")
        app.swipeDown(velocity: .fast)
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        sleep(2)
        snap("iphone-7-pdf")
    }

    func testReadAloudFollowsTheText() throws {
        openFolder("Fiction")
        open(bookMatching: "Тепло и порядок")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 10))
        app.buttons["Contents"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Глава первая'")).firstMatch.tap()
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapter '")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        sleep(1)
        let startChapter = chapterNumber(indicator.label)
        app.buttons["Read aloud"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "Player bar did not appear")
        sleep(2)
        snap("speech-1-reading")
        // Chapter 1 is a few short lines; when speech moves on, the reader must follow into chapter 2.
        let moved = NSPredicate { _, _ in self.chapterNumber(indicator.label) > startChapter }
        wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: 40)
        snap("speech-2-followed")
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 5))
    }

    /// While reading aloud, tapping a word continues from that word (EPUB and PDF).
    func testTapWordWhileReadingAloud() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Read aloud"].tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        sleep(2)
        let before = pause.value as? String ?? ""
        // The "Ludwig Boltzmann expressed this idea…" paragraph.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.32)).tap()
        sleep(2)
        let after = pause.value as? String ?? ""
        snap("speech-tap-pdf")
        print("PDF before=\(before) | after=\(after)")
        XCTAssertTrue(pause.exists, "Reading stopped after tapping a word")
        XCTAssertNotEqual(after, before, "Tapping a word did not move the reading")
        XCTAssertFalse(after.hasPrefix("Entropy and the Second Law"), "Restarted from the top instead of the tapped word")
        app.buttons["Stop"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice")
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 15))
        sleep(3)
        app.buttons["Read aloud"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        sleep(2)
        // A plain start reads from the top of the page; a tap low on the page must start somewhere else.
        let fromTop = pause.value as? String ?? ""
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)).tap()
        sleep(2)
        let now = pause.value as? String ?? ""
        snap("speech-tap-epub")
        print("EPUB fromTop=\(fromTop) | now=\(now)")
        XCTAssertTrue(pause.exists, "Reading stopped after tapping a word")
        XCTAssertFalse(now.isEmpty)
        XCTAssertNotEqual(now, fromTop, "Tapping a word did not move the reading")
        app.buttons["Stop"].tap()
    }

    /// .docx is converted natively, .doc through WebKit; both open as reflowable books with contents.
    func testWordDocuments() throws {
        openFolder("Word")
        for (name, file) in [("Heat and Order (Word), DOCX", "docx"), ("Heat and Order, DOC", "doc")] {
            open(bookMatching: name)
            let text = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never decreases'")).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 20), "\(file): text not shown")
            sleep(1)
            snap("word-\(file)-1-open")
            XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 5), "\(file): no contents")
            app.buttons["Contents"].tap()
            let second = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Second chapter'")).firstMatch
            XCTAssertTrue(second.waitForExistence(timeout: 5), "\(file): headings not in contents")
            snap("word-\(file)-2-contents")
            second.tap()
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Энтропия'")).firstMatch
                .waitForExistence(timeout: 10), "\(file): second chapter not shown")
            snap("word-\(file)-3-chapter2")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }

        // Word's optional/non-breaking hyphens are control characters; they must not show up as boxes.
        open(bookMatching: "Hyphens, DOC")
        let words = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Optional'")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 20), "Hyphen test document did not open")
        sleep(1)
        snap("word-hyphens")
        XCTAssertNil(words.label.unicodeScalars.first { $0.value < 0x20 && $0.value != 0x0A && $0.value != 0x09 },
                     "Control characters left in the text: \(words.label.debugDescription)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Needs a Russian scanned DjVu at Physics/Russian scan.djvu (copied in by hand; not in the repo).
    func testDjVuRussianSelectionHorizontal() throws { try russianDjVuSelection(swipes: 4) }
    func testDjVuRussianSelectionVertical() throws { try russianDjVuSelection() }
    func testDjVuRussianSelectionAfterGoToPage() throws { try russianDjVuSelection(goTo: 11) }
    func testDjVuRussianSelectionHorizontalAfterSwipes() throws { try russianDjVuSelection(goTo: 9, swipes: 2) }

    private func russianDjVuSelection(goTo: Int? = nil, swipes: Int = 0) throws {
        openFolder("Physics")
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Russian scan'")).firstMatch
        try XCTSkipUnless(book.waitForExistence(timeout: 5), "No Russian scan on this simulator")
        book.tap()
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 15))
        sleep(3)
        if let goTo {
            indicator.tap()
            let field = app.textFields["Go to page"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("\(goTo)\n")
        }
        for _ in 0..<swipes { app.swipeLeft(); sleep(1) }
        sleep(4)
        snap("djvu-ru-1-page-\(goTo ?? swipes)")
        let y = goTo == nil && swipes == 0 ? 0.20 : 0.40             // title page: the author line
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: y)).press(forDuration: 1.2)
        sleep(1)
        snap("djvu-ru-2-after-press")
        XCTAssertTrue(app.buttons["Highlight"].waitForExistence(timeout: 5), "Long press did not select text")
    }

    /// scripts/seed-simulator.sh leaves a newer position from "Test Mac" (p. 3) for the Thermodynamics PDF.
    func testOffersPositionFromAnotherDevice() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        let offer = app.staticTexts["Continue on p. 3?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "No offer to continue from the other device")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From Test Mac'")).firstMatch.exists)
        snap("position-1-offer")
        app.buttons["Go"].tap()
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        let moved = NSPredicate { _, _ in indicator.label == "Page 3 of 3" }
        wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: 5)
        XCTAssertFalse(offer.exists, "Offer stayed after Go")
        snap("position-2-moved")
    }

    /// scripts/seed-simulator.sh registers a "Test Mac" and leaves "Sent from iPhone.pdf" in this device's
    /// transfer folder (local fallback for iCloud).
    func testSendAndReceiveBooksBetweenDevices() throws {
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Imported 1 book from another device'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "Book sent to this device was not imported")
        snap("transfer-1-received")
        openFolder("Sent")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sent from iPhone'")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openFolder("Physics")
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Thermodynamics, PDF'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.press(forDuration: 1.2)
        let sendTo = app.buttons["Send to"]
        XCTAssertTrue(sendTo.waitForExistence(timeout: 5), "No Send to in the book menu")
        sendTo.tap()
        let mac = app.buttons["Test Mac"]
        XCTAssertTrue(mac.waitForExistence(timeout: 5), "Other device not listed")
        snap("transfer-2-menu")
        mac.tap()
        // Choose the folder on the other device: it reported Archive and Physics; Physics is preselected.
        XCTAssertTrue(app.staticTexts["Folder on Test Mac"].waitForExistence(timeout: 5), "No folder picker")
        app.staticTexts["Archive"].tap()
        snap("transfer-2b-folders")
        app.buttons["Send"].tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sent “Thermodynamics” to Test Mac'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "No confirmation")
        snap("transfer-3-sent")

        // From inside the book, too: the reader's toolbar has Send to.
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Send to"].waitForExistence(timeout: 10), "No Send to in the reader")
        app.buttons["Send to"].tap()
        XCTAssertTrue(app.buttons["Test Mac"].waitForExistence(timeout: 5))
        snap("transfer-4-reader-menu")
        app.buttons["Test Mac"].tap()
        // A new folder there, typed in the picker.
        let newFolder = app.textFields["New folder"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5))
        newFolder.tap()
        newFolder.typeText("From iPad")
        snap("transfer-5-new-folder")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sent “Thermodynamics” to Test Mac'")).firstMatch
            .waitForExistence(timeout: 10), "No confirmation in the reader")

        // To an iPad: its iCloud Inbox folders (which mirror its library), delivered into the Inbox.
        sleep(6)
        app.buttons["Send to"].tap()
        XCTAssertTrue(app.buttons["Test iPad"].waitForExistence(timeout: 5))
        app.buttons["Test iPad"].tap()
        XCTAssertTrue(app.staticTexts["Folder in the iCloud Inbox"].waitForExistence(timeout: 5), "iPad target not using the Inbox")
        app.staticTexts["Fiction"].tap()
        snap("transfer-6-inbox-folders")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sent “Thermodynamics” to Test iPad (iCloud Inbox › Fiction)'")).firstMatch
            .waitForExistence(timeout: 10), "No Inbox confirmation")
    }

    /// iPhone simulator with Tasker installed: More › Send to Tasker hands the page link to Tasker,
    /// and Share Link to Page is offered.
    func testSendToTasker() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        sleep(1)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Share Link to Page"].waitForExistence(timeout: 5), "No Share Link to Page")
        let send = app.buttons["Send to Tasker"]
        XCTAssertTrue(send.exists, "No Send to Tasker (is Tasker installed on this simulator?)")
        snap("tasker-1-menu")
        send.tap()
        sleep(3)
        snap("tasker-1b-after-tap")
        let tasker = XCUIApplication(bundleIdentifier: "com.romadinov.tasker")
        // iOS may ask to confirm opening another app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.alerts.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 10) {
            snap("tasker-2-confirm")
            open.tap()
        }
        XCTAssertTrue(tasker.wait(for: .runningForeground, timeout: 15), "Tasker did not open")
        sleep(2)
        snap("tasker-2-captured")
    }

    func testReopensLastBookOnLaunch() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        let indicator = app.buttons.matching(NSPredicate(format: "label MATCHES 'Page [0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        sleep(1)
        app.terminate()
        app.launch()
        XCTAssertTrue(indicator.waitForExistence(timeout: 15), "Last book not reopened")
        XCTAssertTrue(app.navigationBars["Thermodynamics"].exists || app.staticTexts["Thermodynamics"].exists)
        snap("reopen-1-book")
        // Back goes to its folder; then the next launch starts in the library.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Physics"].waitForExistence(timeout: 5), "Back did not go to the book's folder")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10), "Should start in the library after closing the book")
    }

    func testShowsTimeLeftAfterAFewPages() throws {
        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice, EPUB")
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chapter '")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 20))
        sleep(3)
        for _ in 0..<7 {                 // read a few pages at ~4 s a page
            app.webViews.firstMatch.swipeLeft()
            sleep(4)
        }
        let label = app.buttons.matching(NSPredicate(format: "label CONTAINS ' left'")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), "No time-left estimate in the toolbar")
        snap("pace-1-toolbar")
        indicator.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'About ' AND label CONTAINS 'a page'")).firstMatch
            .waitForExistence(timeout: 5), "No pace in the page picker")
        snap("pace-2-picker")
    }

    /// No Mail account on the simulator: after asking for the Kindle address it falls back to the share sheet.
    func testSendToKindle() throws {
        openFolder("Physics")
        let djvu = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Thermodynamics, DJVU'")).firstMatch
        XCTAssertTrue(djvu.waitForExistence(timeout: 5))
        djvu.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Send to"].waitForExistence(timeout: 5))
        app.buttons["Send to"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["Send to Kindle"].exists, "DjVu isn't a Kindle format")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        sleep(1)

        let pdf = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Thermodynamics, PDF'")).firstMatch
        pdf.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Send to"].waitForExistence(timeout: 5))
        app.buttons["Send to"].tap()
        let kindle = app.buttons["Send to Kindle"]
        XCTAssertTrue(kindle.waitForExistence(timeout: 5), "No Send to Kindle for a PDF")
        kindle.tap()
        let field = app.textFields["name@kindle.com"]
        if field.waitForExistence(timeout: 5) {          // first time: asks for the address
            field.tap()
            field.typeText("reader_test@kindle.com")
            snap("kindle-1-address")
            app.buttons["Continue"].tap()
        }
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
                      || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2)
                      || app.buttons["Copy"].waitForExistence(timeout: 2), "No share sheet")
        snap("kindle-2-share")
    }

    func testKindleAZW3() throws {
        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice (Kindle), AZW3")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 30), "AZW3 did not open")
        app.buttons["Contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS 'CHAPTER IV'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 5), "No contents")
        snap("azw3-1-contents")
        chapter.tap()
        let text = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Jane'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15), "Chapter text not shown")
        sleep(1)
        snap("azw3-2-chapter")
    }

    func testFileOperationsSwipeMoveSelectDelete() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone)
        openFolder("Physics")
        // Swipe → Delete asks first; Cancel keeps the book.
        let linked = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Linked'")).firstMatch
        XCTAssertTrue(linked.waitForExistence(timeout: 10))
        linked.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Delete “Linked”'")).firstMatch
            .waitForExistence(timeout: 5), "No delete confirmation")
        snap("files-1-confirm")
        confirm.tap()
        XCTAssertTrue(linked.waitForNonExistence(timeout: 5), "Book not deleted")

        // Swipe → Move → new folder "Archive" inside Library.
        let pdf = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Thermodynamics, PDF'")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        pdf.swipeLeft()
        app.buttons["Move"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Move'")).firstMatch.waitForExistence(timeout: 5))
        snap("files-2-move")
        app.buttons["New folder in Library"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Archive")
        app.buttons["Save"].tap()
        XCTAssertTrue(pdf.waitForNonExistence(timeout: 5), "Book not moved")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openFolder("Archive")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Thermodynamics'")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Select two books in Fiction and delete them together.
        openFolder("Fiction")
        app.buttons["Select"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Pride'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Тепло'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 3))
        snap("files-3-selected")
        app.toolbars.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Delete 2 items?"].waitForExistence(timeout: 5))
        app.buttons["Delete 2 Items"].tap()
        XCTAssertTrue(app.staticTexts["Empty folder"].waitForExistence(timeout: 5), "Selected books not deleted")
        snap("files-4-empty")
    }

    func testAssistantRefusesUnsupportedLanguageAndShowsContext() throws {
        // Russian page + Apple's on-device model (which doesn't support Russian) → explanation, no junk.
        openFolder("Fiction")
        open(bookMatching: "Тепло и порядок")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Assistant"].tap()
        app.buttons["Summarize page"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The on-device model can'")).firstMatch
            .waitForExistence(timeout: 10), "No unsupported-language notice")
        snap("ai-1-unsupported")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // English page: a real answer, with the page text that was sent available under the question.
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Assistant"].tap()
        app.buttons["Summarize page"].tap()
        waitForAnswer()
        let sent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page text sent'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "No 'page text sent' disclosure")
        sent.tap()
        snap("ai-2-summary-with-context")
    }

    func testTypedQuestionKeepsSelectionAndMeaningBubble() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Assistant"].waitForExistence(timeout: 10))
        sleep(2)
        // Select a word, open the assistant, type in the field (which takes focus from the page).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.235)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Ask…"].waitForExistence(timeout: 5))
        app.buttons["Ask…"].tap()
        let field = app.textFields["Ask about the selection…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Selection not attached to the question")
        XCTAssertTrue(app.buttons["What does it mean?"].exists, "No default bubble")
        field.tap()
        field.typeText("Why is this here?\n")
        let asked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '“' AND label ENDSWITH '— Why is this here?'")).firstMatch
        XCTAssertTrue(asked.waitForExistence(timeout: 5), "Typed question was sent without the selection")
        waitForAnswer()
        snap("meaning-1-typed")
        // The bubble is still offered for follow-ups.
        app.buttons["What does it mean?"].tap()
        waitForAnswer()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'What does it mean? “'")).firstMatch.exists)
        snap("meaning-2-bubble")
    }

    func testBackPillGoesAwayWhenReadingOn() throws {
        openFolder("Fiction")
        open(bookMatching: "Pride and Prejudice")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 15))
        sleep(2)
        app.buttons["Contents"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'CHAPTER V.'")).firstMatch.tap()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No Back pill after a contents jump")
        sleep(2)
        // Read on: one page keeps it (maybe a peek), two pages from the landing page dismiss it.
        app.webViews.firstMatch.swipeLeft()
        sleep(1)
        XCTAssertTrue(back.exists, "Back pill vanished after one page")
        app.webViews.firstMatch.swipeLeft()
        sleep(1)
        snap("backpill-1-after-reading-on")
        XCTAssertTrue(back.waitForNonExistence(timeout: 3), "Back pill did not go away after reading on")

        // × closes it straight away.
        app.buttons["Contents"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'CHAPTER II.'")).firstMatch.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        app.buttons["Forget"].tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 3), "× did not close the Back pill")
    }

    func testImprovementNoteFromReader() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        sleep(1)
        app.buttons["More"].tap()
        app.buttons["Suggest an Improvement…"].tap()
        let field = app.textFields["What could be better? Bugs, ideas, wishes…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Note form did not open")
        field.typeText("Test note from UI test")
        XCTAssertTrue(app.switches["Attach screenshot"].exists)
        snap("note-1-form")
        app.buttons["Save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Note was not saved")
    }

    /// Recognising text while the PDF view is drawing must not crash (PDFKit documents aren't thread-safe).
    func testRecognizeWhileScrollingPDF() throws {
        openFolder("Physics")
        open(bookMatching: "Thermodynamics, PDF")
        XCTAssertTrue(app.buttons["Text"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["Text"].tap()
            app.buttons["Recognize whole document"].tap()
            for _ in 0..<4 {
                app.swipeUp(velocity: .fast)
                app.swipeDown(velocity: .fast)
            }
            app.buttons["Text"].tap()
            app.buttons["Recognize text on this page"].tap()
        }
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "App crashed while recognising text")
        snap("ocr-1-after")
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

        // In the book: Contents › Bookmarks lists it and jumps there.
        indicator.tap()                                    // page picker → move away from page 2 first
        let goField = app.textFields["Go to page"]
        XCTAssertTrue(goField.waitForExistence(timeout: 5))
        goField.tap()
        goField.typeText("1\n")
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 5))
        app.buttons["Contents"].tap()
        app.buttons["Bookmarks"].tap()
        let mark = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'p. 2'")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "Bookmark not in Contents › Bookmarks")
        snap("bookmarks-1b-contents-tab")
        mark.tap()
        XCTAssertEqual(indicator.label, "Page 2 of 3", "Bookmark did not open its page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Bookmarks"].tap()
        let search = app.searchFields["Search bookmarks, highlights, notes and books"]
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
        // A crowded toolbar collapses the search field into a Search button.
        let librarySearch = app.searchFields["Search all books"]
        if !librarySearch.waitForExistence(timeout: 3), app.buttons["Search"].exists { app.buttons["Search"].tap() }
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5))
        librarySearch.tap()
        librarySearch.typeText("тепло")
        sleep(2)
        snap("search-0-files")
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
