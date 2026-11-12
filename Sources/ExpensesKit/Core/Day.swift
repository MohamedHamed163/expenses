import Foundation

/// Calendar day stored as an integer yyyymmdd (e.g. 20260315).
/// Integers sort correctly, index compactly, and make month/year
/// grouping a matter of integer division: day / 100 = yyyymm, day / 10000 = yyyy.
public struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: Int

    public init?(_ value: Int) {
        let y = value / 10000, m = (value / 100) % 100, d = value % 100
        guard (1900...2200).contains(y), (1...12).contains(m), d >= 1, d <= Day.daysIn(year: y, month: m) else { return nil }
        self.value = value
    }

    public init?(year: Int, month: Int, day: Int) {
        self.init(year * 10000 + month * 100 + day)
    }

    public init(_ date: Date) {
        let c = Day.calendar.dateComponents([.year, .month, .day], from: date)
        value = c.year! * 10000 + c.month! * 100 + c.day!
    }

    /// Accepts "2026-03-15", "2026/03/15", "15/03/2026", "15-03-2026" and Arabic-Indic digits.
    public init?(parsing raw: String) {
        let s = Money.westernizeDigits(raw).trimmingCharacters(in: .whitespaces)
        let parts = s.split(whereSeparator: { "-/. ".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        if parts[0] > 31 { self.init(year: parts[0], month: parts[1], day: parts[2]) }
        else if parts[2] > 31 { self.init(year: parts[2], month: parts[1], day: parts[0]) }
        else { return nil }
    }

    public static var today: Day { Day(Date()) }

    public var year: Int { value / 10000 }
    public var month: Int { (value / 100) % 100 }
    public var dayOfMonth: Int { value % 100 }
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, dayOfMonth) }
    public var description: String { iso }

    public var date: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    public func adding(days n: Int) -> Day {
        Day(Day.calendar.date(byAdding: .day, value: n, to: date)!)
    }

    public func adding(months n: Int) -> Day {
        Day(Day.calendar.date(byAdding: .month, value: n, to: date)!)
    }

    public var startOfMonth: Day { Day(year: year, month: month, day: 1)! }
    public var endOfMonth: Day { Day(year: year, month: month, day: Day.daysIn(year: year, month: month))! }
    public var startOfYear: Day { Day(year: year, month: 1, day: 1)! }
    public var endOfYear: Day { Day(year: year, month: 12, day: 31)! }

    public static func < (a: Day, b: Day) -> Bool { a.value < b.value }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A date range from loose input the AI may send: "2026", "2026-03" or "2026-03-15".
    public static func range(loose raw: String) -> ClosedRange<Day>? {
        let s = Money.westernizeDigits(raw).trimmingCharacters(in: .whitespaces)
        let parts = s.split(whereSeparator: { "-/".contains($0) }).compactMap { Int($0) }
        if parts.count == 1, let y = Day(year: parts[0], month: 1, day: 1) { return y...y.endOfYear }
        if parts.count == 2, parts[0] > 31, let m = Day(year: parts[0], month: parts[1], day: 1) { return m...m.endOfMonth }
        if let d = Day(parsing: s) { return d...d }
        return nil
    }
}
