import Testing
import Foundation
@testable import ExpensesKit

@Suite("Money")
struct MoneyTests {
    @Test func parsesCommonAmountFormats() {
        #expect(Money.parseAmount("1,234.50") == Decimal(string: "1234.50"))
        #expect(Money.parseAmount("1.234,50") == Decimal(string: "1234.50"))
        #expect(Money.parseAmount("12,50") == Decimal(string: "12.50"))
        #expect(Money.parseAmount("1,250") == Decimal(1250))
        #expect(Money.parseAmount("$ 99") == Decimal(99))
        #expect(Money.parseAmount("١٬٢٣٤٫٥٠ ج.م") == Decimal(string: "1234.50"))
        #expect(Money.parseAmount("abc") == nil)
    }

    @Test func normalizesCurrencies() {
        #expect(Money.normalizeCurrency("egp") == "EGP")
        #expect(Money.normalizeCurrency("ج.م") == "EGP")
        #expect(Money.normalizeCurrency("E£") == "EGP")
        #expect(Money.normalizeCurrency("ر.س") == "SAR")
        #expect(Money.normalizeCurrency("US$") == "USD")
        #expect(Money.normalizeCurrency("$") == "USD")
        #expect(Money.normalizeCurrency("€") == "EUR")
        #expect(Money.normalizeCurrency("ريال") == nil)        // ambiguous: SAR/QAR/OMR -> review
        #expect(Money.normalizeCurrency(nil) == nil)
    }

    @Test func minorUnitsRespectCurrencyDigits() {
        #expect(Money.toMinor(Decimal(string: "12.345")!, currency: "KWD") == 12345)
        #expect(Money.toMinor(Decimal(string: "12.345")!, currency: "USD") == 1235)   // rounds half away from zero
        #expect(Money.toMinor(Decimal(500), currency: "JPY") == 500)
    }

    @Test func convertsToUSDWithFrozenRate() {
        // 1,368.00 EGP at 0.0205 USD/EGP = 28.044 -> $28.04
        #expect(Money.usdMinor(amountMinor: 136_800, currency: "EGP", rateE6: 20_500) == 2804)
        // 10.000 KWD at 3.25 = $32.50
        #expect(Money.usdMinor(amountMinor: 10_000, currency: "KWD", rateE6: 3_250_000) == 3250)
        #expect(Money.usdMinor(amountMinor: 999, currency: "USD", rateE6: 1) == 999)
        #expect(Money.format(123456) == "$1,234.56")
    }
}

@Suite("Day")
struct DayTests {
    @Test func parsesAndValidates() {
        #expect(Day(parsing: "2026-03-14")?.value == 20260314)
        #expect(Day(parsing: "14/03/2026")?.value == 20260314)
        #expect(Day(parsing: "١٤/٠٣/٢٠٢٦")?.value == 20260314)
        #expect(Day(parsing: "2026-02-30") == nil)
        #expect(Day(parsing: "2024-02-29") != nil)
        #expect(Day(parsing: "03/14") == nil)
    }

    @Test func looseRanges() {
        #expect(Day.range(loose: "2025") == d("2025-01-01")...d("2025-12-31"))
        #expect(Day.range(loose: "2026-02") == d("2026-02-01")...d("2026-02-28"))
        #expect(Day.range(loose: "2026-03-05") == d("2026-03-05")...d("2026-03-05"))
        #expect(Day.range(loose: "March") == nil)
    }
}

@Suite("Validator")
struct ValidatorTests {
    let today = d("2026-11-12")
    func good() throws -> ExtractedInvoice { try InvoiceExtractor.parse(json: goodInvoiceJSON, categoryKeys: ["groceries", "other"]) }

    @Test func autoConfirmsWhenEveryCheckPasses() throws {
        let decision = Validator.decide(try good(), today: today, hasRate: true, duplicateOf: nil)
        #expect(decision == .init(autoConfirm: true, reasons: []))
    }

    @Test func eachFailingRuleSendsToReview() throws {
        var e = try good(); e.confidence = 0.6
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons == ["Low AI confidence (60%)"])
        e = try good(); e.day = d("2026-12-01")
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons == ["Date is in the future"])
        e = try good(); e.day = d("2010-01-01")
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons == ["Date is more than 10 years old"])
        e = try good(); e.lineItems = []
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons == ["No line items to cross-check the total"])
        e = try good(); e.totalMinor = 200_000
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons.first?.hasPrefix("Line items add up") == true)
        e = try good(); e.currency = nil
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).reasons == ["Currency not recognized"])
        #expect(Validator.decide(try good(), today: today, hasRate: false, duplicateOf: nil).reasons == ["No exchange rate for EGP"])
        #expect(Validator.decide(try good(), today: today, hasRate: true, duplicateOf: 7).reasons == ["Possible duplicate of invoice #7"])
    }

    @Test func lineItemsWithinOnePercentPass() throws {
        var e = try good()
        e.subtotalMinor = nil; e.taxMinor = nil
        e.totalMinor = 120_000 + 1_000   // items 1,200.00 vs total 1,210.00 = 0.83% off
        #expect(Validator.decide(e, today: today, hasRate: true, duplicateOf: nil).autoConfirm)
    }
}

@Suite("Extraction parsing")
struct ExtractionParsingTests {
    @Test func normalizesModelOutput() throws {
        let e = try InvoiceExtractor.parse(json: goodInvoiceJSON, categoryKeys: ["groceries", "other"])
        #expect(e.vendor == "Carrefour Maadi")
        #expect(e.day == d("2026-03-14"))
        #expect(e.currency == "EGP")
        #expect(e.totalMinor == 136_800 && e.subtotalMinor == 120_000 && e.taxMinor == 16_800)
        #expect(e.lineItems.map(\.totalMinor) == [70_000, 50_000])
    }

    @Test func arabicInvoiceWithArabicDigitsAndUnknownCategory() throws {
        let json = #"{"vendor":"صيدلية العزبي","date":"٠٥/١٠/٢٠٢٦","currency":"ج.م","total":"٢٥٠٫٧٥","category":"pharmacy","line_items":[],"confidence":"0.8"}"#
        let e = try InvoiceExtractor.parse(json: json, categoryKeys: ["health", "other"])
        #expect(e.vendor == "صيدلية العزبي")
        #expect(e.day == d("2026-10-05"))
        #expect(e.currency == "EGP")
        #expect(e.totalMinor == 25_075)
        #expect(e.categoryKey == "other")
        #expect(e.confidence == 0.8)
    }

    @Test func pullsJSONOutOfChattyReply() {
        #expect(extractJSONObject("Sure!\n```json\n{\"a\":1}\n```") == "{\"a\":1}")
        #expect(extractJSONObject("no json here") == nil)
    }
}

@Suite("Voice language")
struct VoiceLanguageTests {
    @Test func usesDetectedLanguageWhenSupported() {
        #expect(VoiceLanguage.choose(detected: "en", logProbs: ["en": -0.003]) == "en")
        #expect(VoiceLanguage.choose(detected: "ar", logProbs: ["ar": -0.005]) == "ar")
    }
    @Test func logProbsMissingLanguageIsNotZero() {
        // Regression: a missing key used to default to 0, which beats any log-prob and flipped the language.
        #expect(VoiceLanguage.choose(detected: "fa", logProbs: ["fa": -0.2, "en": -3.0]) == "en")
        #expect(VoiceLanguage.choose(detected: "fa", logProbs: ["fa": -0.2, "ar": -1.1, "en": -3.0]) == "ar")
        #expect(VoiceLanguage.choose(detected: "ur", logProbs: ["ur": -0.1]) == "ar")
    }
}
