import Foundation
import Testing
@testable import ReaderCore

@Test func readingPaceLearnsFromPageTurnsAndEstimatesTimeLeft() {
    var pace = ReadingPace()
    let skim = pace.record(1)           // skimming
    let away = pace.record(3600)        // stepped away
    #expect(!skim && !away && pace.samples.isEmpty)
    for seconds in [60.0, 70, 65, 80] { pace.record(seconds) }
    #expect(pace.secondsPerPage == nil)  // not enough pages yet
    pace.record(75)
    #expect(pace.secondsPerPage == 70)   // median of 60, 65, 70, 75, 80
    #expect(pace.timeLeft(pages: 360) == 25_200.0, "got \(String(describing: pace.timeLeft(pages: 360)))")
    #expect(pace.timeLeft(pages: 0) == nil)

    // A new book borrows the overall pace until it has its own.
    let fresh = ReadingPace()
    #expect(fresh.timeLeft(pages: 10, fallback: pace) == 700)

    // Keeps only the most recent pages.
    for _ in 0..<100 { pace.record(30) }
    #expect(pace.samples.count == ReadingPace.memory && pace.secondsPerPage == 30)

    #expect(ReadingPace.describe(25) == "under a minute")
    #expect(ReadingPace.describe(25 * 60) == "25 min")
    #expect(ReadingPace.describe(6 * 3600 + 12 * 60) == "6 h 12 min")
    #expect(ReadingPace.describe(2 * 3600) == "2 h")
    #expect(ReadingPace.describe(14 * 3600 + 20 * 60) == "14 h")
}

@Suite struct ReadingPaceOutlierTests {
    @Test func ignoresSkimsAndInterruptionsOnceKnown() {
        var pace = ReadingPace()
        for s in [60.0, 70, 65, 55, 62] { pace.record(s) }
        let skim = pace.record(8)          // flicking through pages already read
        let away = pace.record(500)        // wrote a suggestion, or the lid was closed
        let normal = pace.record(80)
        #expect(!skim && !away && normal)
        #expect(pace.samples.count == 6)
        #expect(pace.secondsPerPage == 63.5)
    }
}
