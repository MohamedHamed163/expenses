import Foundation

/// The agreed auto-confirm policy. An invoice counts in totals automatically
/// only when every check passes; otherwise it waits in "Needs review".
public enum Validator {
    public static let minConfidence = 0.9
    public static let tolerance = 0.01   // ±1%

    public struct Decision: Sendable, Equatable {
        public var autoConfirm: Bool
        public var reasons: [String]
    }

    public static func decide(_ e: ExtractedInvoice, today: Day = .today, hasRate: Bool, duplicateOf: Int64?) -> Decision {
        var reasons: [String] = []
        if e.totalMinor == nil { reasons.append("Total not found") }
        else if let t = e.totalMinor, t <= 0 { reasons.append("Total is not positive") }
        if e.vendor == nil { reasons.append("Vendor not found") }
        if e.currency == nil { reasons.append("Currency not recognized") }
        else if !hasRate { reasons.append("No exchange rate for \(e.currency!)") }
        if let d = e.day {
            if d > today { reasons.append("Date is in the future") }
            if d < Day(year: today.year - 10, month: today.month, day: min(today.dayOfMonth, 28))! { reasons.append("Date is more than 10 years old") }
        } else {
            reasons.append("Date not found")
        }
        if e.confidence < minConfidence {
            reasons.append(String(format: "Low AI confidence (%.0f%%)", e.confidence * 100))
        }
        if let t = e.totalMinor {
            switch lineItemsCheck(e, total: t) {
            case .ok: break
            case .noItems: reasons.append("No line items to cross-check the total")
            case .mismatch(let sum):
                let cur = e.currency ?? Money.base
                reasons.append("Line items add up to \(Money.format(sum, currency: cur)) but the total is \(Money.format(t, currency: cur))")
            }
        }
        if let dup = duplicateOf { reasons.append("Possible duplicate of invoice #\(dup)") }
        return Decision(autoConfirm: reasons.isEmpty, reasons: reasons)
    }

    enum ItemsCheck: Equatable { case ok, noItems, mismatch(Int64) }

    /// Line items must explain the total: directly, via subtotal + tax, or items + tax.
    static func lineItemsCheck(_ e: ExtractedInvoice, total: Int64) -> ItemsCheck {
        guard !e.lineItems.isEmpty else { return .noItems }
        let sum = e.lineItems.reduce(Int64(0)) { $0 + $1.totalMinor }
        func close(_ a: Int64, _ b: Int64) -> Bool { Double(abs(a - b)) <= max(Double(abs(b)) * tolerance, 1) }
        if close(sum, total) { return .ok }
        if let sub = e.subtotalMinor, close(sum, sub) {
            if close(sub + (e.taxMinor ?? 0), total) { return .ok }
        }
        if let tax = e.taxMinor, close(sum + tax, total) { return .ok }
        return .mismatch(sum)
    }
}
