import Testing
import Foundation
@testable import ExpensesKit

@Suite("Store")
struct StoreTests {
    @Test func migrationsAreIdempotentAndSeedReferenceData() async throws {
        let (store, dir) = try await makeStore()
        #expect(try await store.categories().count == 12)
        let again = try await ExpenseStore(config: store.config)   // reopen: no duplicate seeds
        #expect(try await again.categories().count == 12)
        #expect(try await again.rateE6(currency: "EGP", on: d("2026-01-01")) == 20_500)
        try? await store.dropSchema(); try? FileManager.default.removeItem(at: dir)
    }

    @Test func aggregatesByMonthCategoryAndVendorWithGaps() async throws {
        let (store, _) = try await makeStore()
        try await store.addExpense(NewExpense(day: d("2026-01-10"), amountMinor: 1000, currency: "USD", categoryKey: "food", vendor: "Cafe A"))
        try await store.addExpense(NewExpense(day: d("2026-01-20"), amountMinor: 2000, currency: "USD", categoryKey: "transport", vendor: "Uber"))
        try await store.addExpense(NewExpense(day: d("2026-03-05"), amountMinor: 4000, currency: "USD", categoryKey: "food", vendor: "cafe a"))
        let f = ExpenseFilter(from: d("2026-01-01"), to: d("2026-03-31"))
        let months = try await store.aggregate(f, groupBy: .month)
        #expect(months.map(\.usdMinor) == [3000, 0, 4000])          // February filled with 0
        #expect(months.map(\.label) == ["Jan 2026", "Feb 2026", "Mar 2026"])
        let cats = try await store.aggregate(f, groupBy: .category)
        #expect(cats.first?.key == "food" && cats.first?.usdMinor == 5000)
        let vendors = try await store.aggregate(f, groupBy: .vendor)
        #expect(vendors.first?.usdMinor == 5000)                      // "Cafe A" and "cafe a" are one vendor
        #expect(try await store.aggregate(ExpenseFilter(from: d("2026-01-01"), to: d("2026-01-31"), categoryKey: "food"), groupBy: .none).first?.usdMinor == 1000)
        #expect(try await store.aggregate(ExpenseFilter(vendor: "uber"), groupBy: .none).first?.usdMinor == 2000)
    }

    @Test func keysetPaginationReturnsEveryRowOnceInOrder() async throws {
        let (store, _) = try await makeStore()
        for i in 0..<57 {
            try await store.addExpense(NewExpense(day: d("2026-05-01").adding(days: i % 9), amountMinor: Int64(100 + i), currency: "USD", categoryKey: "other"))
        }
        var seen: [Expense] = []
        var cursor: PageCursor? = nil
        repeat {
            let page = try await store.listExpenses(limit: 10, after: cursor)
            seen += page.rows
            cursor = page.next
        } while cursor != nil
        #expect(seen.count == 57)
        #expect(Set(seen.map(\.id)).count == 57)
        #expect(seen == seen.sorted { ($0.day, $0.id) > ($1.day, $1.id) })
    }

    @Test func frozenRateDoesNotChangeOldExpenses() async throws {
        let (store, _) = try await makeStore()
        let id = try await store.addExpense(NewExpense(day: d("2026-03-01"), amountMinor: 100_000, currency: "EGP", categoryKey: "food"))
        #expect(try await store.expense(id).usdMinor == 2050)
        try await store.setRate(currency: "EGP", day: d("2026-06-01"), usdPerUnit: Decimal(string: "0.02")!)
        #expect(try await store.expense(id).usdMinor == 2050)          // unchanged
        let later = try await store.addExpense(NewExpense(day: d("2026-07-01"), amountMinor: 100_000, currency: "EGP", categoryKey: "food"))
        #expect(try await store.expense(later).usdMinor == 2000)       // new rate applies to new dates
        await #expect(throws: ExpensesError.noRate(currency: "XYZ")) {
            try await store.addExpense(NewExpense(day: d("2026-07-01"), amountMinor: 1, currency: "XYZ", categoryKey: "food"))
        }
    }

    @Test func everyWriteIsUndoable() async throws {
        let (store, _) = try await makeStore()
        let all = ExpenseFilter()
        func total() async throws -> Int64 { try await store.aggregate(all, groupBy: .none).first?.usdMinor ?? 0 }

        let a = try await store.addExpense(NewExpense(day: d("2026-04-01"), amountMinor: 5000, currency: "USD", categoryKey: "food"))
        try await store.editExpense(a, ExpenseEdit(amountMinor: 7000, categoryKey: "travel"))
        #expect(try await total() == 7000)
        try await store.undoLast()                                      // undo edit
        #expect(try await store.expense(a).amountMinor == 5000)
        #expect(try await store.expense(a).categoryKey == "food")

        let parts = try await store.splitExpense(a, parts: [(3000, "food"), (2000, "electronics")])
        #expect(parts.count == 2)
        #expect(try await store.aggregate(all, groupBy: .category).count == 2)
        try await store.undoLast()                                      // undo split
        #expect(try await store.aggregate(all, groupBy: .category).map(\.key) == ["food"])

        try await store.deleteExpenses([a])
        #expect(try await total() == 0)
        try await store.undoLast()                                      // undo delete
        #expect(try await total() == 5000)

        try await store.undoLast()                                      // undo the original add
        #expect(try await total() == 0)
        await #expect(throws: ExpensesError.nothingToUndo) { try await store.undoLast() }
    }

    @Test func failedWriteRollsBackCompletely() async throws {
        let (store, _) = try await makeStore()
        let a = try await store.addExpense(NewExpense(day: d("2026-04-01"), amountMinor: 5000, currency: "USD", categoryKey: "food"))
        // Parts don't sum to the original: whole transaction must roll back.
        await #expect(throws: ExpensesError.self) { try await store.splitExpense(a, parts: [(3000, "food"), (1000, "travel")]) }
        #expect(try await store.expense(a).amountMinor == 5000)          // original not deleted
        #expect(try await store.auditLog().count == 1)                  // no audit row for the failed split
        // Deleting a mix of valid + missing ids deletes nothing.
        await #expect(throws: ExpensesError.self) { try await store.deleteExpenses([a, 999]) }
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 5000)
    }

    @Test func concurrentWritersAreSerialized() async throws {
        let (store, _) = try await makeStore()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask { _ = try? await store.addExpense(NewExpense(day: d("2026-02-01"), amountMinor: Int64(i + 1), currency: "USD", categoryKey: "other")) }
            }
        }
        let row = try await store.aggregate(ExpenseFilter(), groupBy: .none).first!
        #expect(row.count == 200)
        #expect(row.usdMinor == (1...200).reduce(0, +))
    }
}

@Suite("Scale", .enabled(if: ProcessInfo.processInfo.environment["EXPENSES_BENCH"] == "1"))
struct ScaleTests {
    @Test func oneMillionRowsChartQueriesStayFast() async throws {
        let (store, dir) = try await makeStore()
        let t0 = Date()
        try await store.seedSynthetic(count: 1_000_000, from: d("2016-01-01"), days: 3653)
        print("seed 1M rows: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        let lastYear = ExpenseFilter(from: d("2025-01-01"), to: d("2025-12-31"))
        let cases: [(String, ExpenseFilter, GroupBy)] = [
            ("last year by month", lastYear, .month),
            ("last year by day", lastYear, .day),
            ("all time by year", ExpenseFilter(), .year),
            ("last year by category", lastYear, .category),
            ("one month total", ExpenseFilter(from: d("2025-06-01"), to: d("2025-06-30")), .none),
            ("food last year by month", ExpenseFilter(from: d("2025-01-01"), to: d("2025-12-31"), categoryKey: "food"), .month),
        ]
        for (name, f, g) in cases {
            _ = try await store.aggregate(f, groupBy: g)   // warm
            let t = Date()
            let rows = try await store.aggregate(f, groupBy: g)
            let ms = Date().timeIntervalSince(t) * 1000
            print("\(name): \(String(format: "%.1f", ms)) ms (\(rows.count) rows)")
            if name != "all time by year" && name != "last year by category" { #expect(ms < 50, "\(name) took \(ms) ms") }
        }
        let t = Date()
        var cursor: PageCursor? = nil
        for _ in 0..<100 { cursor = try await store.listExpenses(limit: 50, after: cursor).next }
        print("100 pages of 50 (keyset): \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms")
        for line in try await store.explain("SELECT day/100, SUM(usd_minor) FROM expenses e WHERE e.deleted_at IS NULL AND e.day >= 20250101 AND e.day <= 20251231 GROUP BY 1") {
            print("plan: \(line)")
        }
        try? await store.dropSchema(); try? FileManager.default.removeItem(at: dir)
    }
}
