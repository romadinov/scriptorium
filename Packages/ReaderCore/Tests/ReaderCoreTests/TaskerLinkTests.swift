import Foundation
import Testing
@testable import ReaderCore

@Suite struct TaskerLinkTests {
    @Test func encodesEachValueSeparately() throws {
        let link = DeepLink(documentID: "abc", page: 11, progress: 0.25, highlightID: nil).url
        let url = TaskerLink.add(title: "Physics & Co — p. 12", url: link, note: "E = mc² & more")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.scheme == "tasker" && url.host() == "add")
        #expect(value("title") == "Physics & Co — p. 12")
        #expect(value("url") == link.absoluteString)               // the deep link's own ? and & survive
        #expect(value("note") == "E = mc² & more")
        #expect(value("quick") == "1" && value("x-success") == "scriptorium://")
        #expect(DeepLink(url: URL(string: value("url")!)!) == DeepLink(documentID: "abc", page: 11, progress: 0.25))
    }

    @Test func quickEntryAndEmptyNoteAreOmitted() throws {
        let url = TaskerLink.add(title: "T", url: URL(string: "scriptorium://open?doc=x&page=0")!, note: "", quick: false)
        let names = Set(try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
        #expect(names == ["title", "url"])
    }

    @Test func locationTitles() {
        #expect(ReadingLocationTitle.make(book: "Thermodynamics", page: 41, chapterTitle: nil) == "Thermodynamics — p. 42")
        #expect(ReadingLocationTitle.make(book: "Pride", page: 3, chapterTitle: "Chapter 4") == "Pride — Chapter 4")
    }
}
