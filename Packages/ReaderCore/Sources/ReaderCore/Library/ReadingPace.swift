import Foundation

/// How fast someone reads, learned from page turns: the median time per page over the last pages read.
/// Skimming (very quick turns) and pauses (long gaps) are left out.
public struct ReadingPace: Codable, Sendable, Equatable {
    /// Seconds spent on each recently read page, newest last.
    public private(set) var samples: [Double] = []

    public static let fastest: Double = 3          // quicker = flicking through, not reading
    public static let slowest: Double = 600        // longer = stepped away
    public static let memory = 40
    public static let minimumSamples = 5

    public init(samples: [Double] = []) { self.samples = samples }

    /// Records the time spent on one page. Returns false if it was skimming or a pause.
    @discardableResult
    public mutating func record(_ seconds: Double) -> Bool {
        guard seconds >= Self.fastest, seconds <= Self.slowest else { return false }
        // Once the pace is known, far quicker pages are skimming and far slower ones are interruptions.
        if let typical = secondsPerPage, seconds < typical * 0.3 || seconds > typical * 4 { return false }
        samples.append(seconds)
        if samples.count > Self.memory { samples.removeFirst(samples.count - Self.memory) }
        return true
    }

    /// Typical seconds per page, once there are enough pages to tell.
    public var secondsPerPage: Double? {
        guard samples.count >= Self.minimumSamples else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Time to read `pages` more pages at this pace (or `fallback`'s, if this one isn't known yet).
    public func timeLeft(pages: Int, fallback: ReadingPace? = nil) -> TimeInterval? {
        guard pages > 0, let pace = secondsPerPage ?? fallback?.secondsPerPage else { return nil }
        return pace * Double(pages)
    }

    /// "6 h 12 min", "25 min", "under a minute".
    public static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 10 || rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) min"
    }
}
