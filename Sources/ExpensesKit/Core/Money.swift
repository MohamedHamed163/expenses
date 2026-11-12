import Foundation

/// Money is always stored as integer minor units (cents, piasters, fils…)
/// in the invoice's own currency, plus a frozen USD conversion.
public enum Money {
    /// The base currency for totals and charts (agreed: USD, fixed).
    public static let base = "USD"

    /// ISO 4217 minor-unit digits for currencies we expect; default 2.
    public static func minorDigits(_ currency: String) -> Int {
        switch currency.uppercased() {
        case "JPY", "KRW", "VND", "CLP", "ISK": return 0
        case "KWD", "BHD", "OMR", "JOD", "TND", "LYD", "IQD": return 3
        default: return 2
        }
    }

    /// Maps a currency code, symbol or Arabic/English name to ISO 4217.
    /// Returns nil when unknown; callers must route that invoice to review.
    public static func normalizeCurrency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let upper = s.uppercased()
        let iso: Set<String> = ["USD", "EGP", "SAR", "AED", "EUR", "GBP", "KWD", "QAR", "BHD", "OMR",
                                "JOD", "JPY", "CNY", "INR", "TRY", "MAD", "CAD", "AUD", "CHF"]
        if iso.contains(upper) { return upper }
        // Order matters: "E£" before "£", "US$" before "$".
        let table: [(String, String)] = [
            ("US$", "USD"), ("E£", "EGP"), ("LE", "EGP"), ("L.E", "EGP"), ("ج.م", "EGP"), ("جنيه", "EGP"),
            ("ر.س", "SAR"), ("ريال سعودي", "SAR"), ("SR", "SAR"), ("د.إ", "AED"), ("درهم", "AED"),
            ("د.ك", "KWD"), ("دينار كويتي", "KWD"), ("ر.ق", "QAR"), ("دولار", "USD"),
            ("€", "EUR"), ("يورو", "EUR"), ("£", "GBP"), ("$", "USD"), ("¥", "JPY"),
        ]
        for (needle, code) in table where s.contains(needle) || upper == needle.uppercased() { return code }
        return nil
    }

    /// Western digits for Arabic-Indic (٠-٩) and Persian (۰-۹) digits and separators.
    public static func westernizeDigits(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x0660...0x0669: out.unicodeScalars.append(UnicodeScalar(ch.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: out.unicodeScalars.append(UnicodeScalar(ch.value - 0x06F0 + 0x30)!)
            case 0x066B: out.append(".")   // Arabic decimal separator
            case 0x066C: out.append(",")   // Arabic thousands separator
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Parses "1,234.50", "1.234,50", "١٢٣٫٥٠", "$ 12" into a Decimal.
    public static func parseAmount(_ raw: String) -> Decimal? {
        var s = westernizeDigits(raw)
        s = String(s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" })
        guard s.contains(where: \.isNumber) else { return nil }
        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        if let d = lastDot, let c = lastComma {
            // The later separator is the decimal one.
            if c > d { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else if let c = lastComma {
            // "12,50" (decimal) vs "1,250" (thousands): 3 digits after comma = thousands.
            let after = s.distance(from: c, to: s.endIndex) - 1
            s = after == 3 ? s.replacingOccurrences(of: ",", with: "") : s.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Decimal major units -> integer minor units (round half away from zero).
    public static func toMinor(_ amount: Decimal, currency: String) -> Int64 {
        let digits = minorDigits(currency)
        var scaled = amount * pow10(digits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func toMajor(_ minor: Int64, currency: String) -> Decimal {
        Decimal(minor) / pow10(minorDigits(currency))
    }

    /// Converts minor units of `currency` to USD cents using a frozen rate
    /// expressed as USD per 1 unit of `currency`, times 1e6.
    public static func usdMinor(amountMinor: Int64, currency: String, rateE6: Int64) -> Int64 {
        if currency.uppercased() == base { return amountMinor }
        let major = toMajor(amountMinor, currency: currency)
        var usd = major * Decimal(rateE6) / Decimal(1_000_000) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &usd, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func rateE6(fromUSDPerUnit d: Decimal) -> Int64 {
        var v = d * 1_000_000
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return NSDecimalNumber(decimal: r).int64Value
    }

    /// Formatting is done by code, never by the LLM: "$1,234.56".
    public static func format(_ minor: Int64, currency: String = base) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = minorDigits(currency)
        f.maximumFractionDigits = minorDigits(currency)
        return f.string(from: NSDecimalNumber(decimal: toMajor(minor, currency: currency))) ?? "\(minor)"
    }

    private static func pow10(_ n: Int) -> Decimal {
        var d = Decimal(1)
        for _ in 0..<n { d *= 10 }
        return d
    }
}
