import Foundation
import Testing
@testable import ReaderCore

@Suite struct ThroughlineLinkTests {
    @Test func encodesEachValueSeparately() throws {
        let link = DeepLink(documentID: "abc", page: 11, progress: 0.25, highlightID: nil).url
        let url = ThroughlineLink.add(title: "Physics & Co — p. 12", url: link, note: "E = mc² & more")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.scheme == "throughline" && url.host() == "add")
        #expect(ThroughlineLink.add(title: "T", url: link, scheme: ThroughlineLink.legacyScheme).scheme == "tasker")
        #expect(value("title") == "Physics & Co — p. 12")
        #expect(value("url") == link.absoluteString)               // the deep link's own ? and & survive
        #expect(value("note") == "E = mc² & more")
        #expect(value("quick") == "1" && value("x-success") == "scriptorium://")
        #expect(DeepLink(url: URL(string: value("url")!)!) == DeepLink(documentID: "abc", page: 11, progress: 0.25))
    }

    @Test func quickEntryAndEmptyNoteAreOmitted() throws {
        let url = ThroughlineLink.add(title: "T", url: URL(string: "scriptorium://open?doc=x&page=0")!, note: "", quick: false)
        let names = Set(try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
        #expect(names == ["title", "url"])
    }

    @Test func locationTitles() {
        #expect(ReadingLocationTitle.make(book: "Thermodynamics", page: 41, chapterTitle: nil) == "Thermodynamics — p. 42")
        #expect(ReadingLocationTitle.make(book: "Pride", page: 3, chapterTitle: "Chapter 4") == "Pride — Chapter 4")
    }

    @Test func deepLinkCarriesAQuoteRoundTrip() throws {
        let quote = TextQuote(exact: "a = b & c + d #1?", prefix: "Since ", suffix: ", we have")
        let link = DeepLink(documentID: "abc", page: 3, progress: 0.5, quote: quote)
        #expect(!link.url.absoluteString.contains("&c") && !link.url.absoluteString.contains("#"))
        #expect(DeepLink(url: link.url) == link)
        // And through Throughline, which encodes the whole link again.
        let tasker = ThroughlineLink.add(title: "T", url: link.url)
        let inner = try #require(URLComponents(url: tasker, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value)
        #expect(DeepLink(url: URL(string: inner)!) == link)
    }

    @Test func quoteTakesContextAndFindsTheRightOccurrence() throws {
        let page = "The cat sat.\nThen the  cat ran away, and the cat slept."
        let quote = TextQuote(selection: "the cat", in: "Then the cat ran away, and the cat slept.")
        #expect(quote.prefix == "Then " && quote.suffix.hasPrefix(" ran away"))
        let range = try #require(quote.locate(in: page))
        #expect(page[range] == "the  cat")                           // original spacing, second line
        #expect(page[range.upperBound...].hasPrefix(" ran away"))
        let last = TextQuote(exact: "the cat", prefix: "and ", suffix: " slept")
        #expect(page[try #require(last.locate(in: page)).upperBound...].hasPrefix(" slept"))
        #expect(TextQuote(exact: "dog").locate(in: page) == nil)
    }

    @Test func longSelectionsAreCapped() {
        let long = String(repeating: "word ", count: 100)
        #expect(TextQuote(selection: long, in: long).exact.count == TextQuote.maxLength)
    }
}
