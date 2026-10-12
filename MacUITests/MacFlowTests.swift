import XCTest

/// End-to-end flows of the Mac app. Run with scripts/test-mac.sh, which seeds the library first.
final class MacFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
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

    private func openBook(_ title: String) -> XCUIElement {
        let library = app.windows["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "No library window")
        let row = library.tables.firstMatch.staticTexts.matching(NSPredicate(format: "value == %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No book \(title)")
        row.doubleClick()
        let window = app.windows[title]
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Book window did not open")
        return window
    }

    func testLibraryAndPDFReader() throws {
        XCTAssertTrue(app.windows["Library"].waitForExistence(timeout: 10))
        sleep(2)
        snap("mac-1-library")
        let window = openBook("Thermodynamics")
        sleep(2)
        snap("mac-2-pdf")
        // Next page, bookmark, then find it in the sidebar.
        window.buttons["Next"].click()
        sleep(1)
        window.buttons["Bookmark"].click()
        XCTAssertTrue(window.buttons["Remove Bookmark"].waitForExistence(timeout: 5), "Bookmark not set")
        app.typeKey("s", modifierFlags: [.command, .control])           // show sidebar
        window.radioButtons["Bookmarks"].click()
        XCTAssertTrue(window.staticTexts["p. 2"].waitForExistence(timeout: 5), "Bookmark not listed")
        snap("mac-3-bookmarks")
        window.buttons["Remove Bookmark"].click()
    }

    func testEPUBDjVuAndKindle() throws {
        let epub = openBook("Pride and Prejudice")
        XCTAssertTrue(epub.webViews.staticTexts.firstMatch.waitForExistence(timeout: 20), "EPUB text not shown")
        sleep(2)
        snap("mac-4-epub")
        epub.typeKey("w", modifierFlags: .command)
        let djvu = openBook("Thermodynamics (DjVu)")
        sleep(4)
        snap("mac-5-djvu")
        djvu.typeKey("w", modifierFlags: .command)
        let kindle = openBook("Pride and Prejudice (Kindle)")
        XCTAssertTrue(kindle.webViews.staticTexts.firstMatch.waitForExistence(timeout: 30), "AZW3 text not shown")
        sleep(2)
        snap("mac-6-azw3")
    }
}
