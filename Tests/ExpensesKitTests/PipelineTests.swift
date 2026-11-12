import Testing
import Foundation
@testable import ExpensesKit

@Suite("Ingestion")
struct IngestTests {
    let today: @Sendable () -> Day = { Day(parsing: "2026-11-12")! }

    func service(_ store: ExpenseStore, _ dir: URL, _ llm: LLM) -> IngestService {
        IngestService(store: store, llm: llm, filesDir: dir.appendingPathComponent("files"), backoff: { _ in }, today: today)
    }

    @Test func goodInvoiceIsAutoConfirmedAndCountsInUSD() async throws {
        let (store, dir) = try await makeStore()
        let pdf = dir.appendingPathComponent("carrefour.pdf")
        try makePDF("Carrefour Maadi\nInvoice INV-1001 14/03/2026\nRice 5kg x2 700.00\nOlive oil 500.00\nSubtotal 1,200.00 VAT 168.00 Total EGP 1,368.00", at: pdf)
        let llm = FakeLLM { msgs, _ in
            #expect(msgs[1].content.contains("Carrefour"))     // the PDF text reached the model
            return reply("Here you go: \(goodInvoiceJSON)")
        }
        let outcome = await service(store, dir, llm).ingest(pdf)
        guard case .confirmed(let id) = outcome else { Issue.record("expected confirmed, got \(outcome)"); return }
        let inv = try await store.invoice(id)
        #expect(inv.status == .confirmed && inv.lineItems.count == 2)
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 2804)   // 1,368 EGP -> $28.04
        #expect(try await store.ftsSearch("olive").first?.invoiceID == id)                            // indexed for RAG
    }

    @Test func sameFileTwiceIsBlockedAndLookalikeIsFlagged() async throws {
        let (store, dir) = try await makeStore()
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b-photo.pdf")
        try makePDF("Carrefour Maadi receipt, total 1,368.00 EGP, rice and olive oil, 14/03/2026", at: a)
        try makePDF("Photo of the Carrefour Maadi receipt (scanned copy) total 1368 EGP 14/03/2026", at: b)
        let svc = service(store, dir, FakeLLM { _, _ in reply(goodInvoiceJSON) })
        guard case .confirmed(let first) = await svc.ingest(a) else { Issue.record("first should confirm"); return }
        #expect(await svc.ingest(a) == .duplicateFile(existingInvoiceID: first))
        let second = await svc.ingest(b)
        guard case .needsReview(_, let reasons) = second else { Issue.record("lookalike should need review, got \(second)"); return }
        #expect(reasons == ["Possible duplicate of invoice #\(first)"])
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.count == 1)          // counted once
    }

    @Test func aiOfflineRetriesThreeTimesThenFailsAndRetrySucceeds() async throws {
        let (store, dir) = try await makeStore()
        let pdf = dir.appendingPathComponent("x.pdf")
        try makePDF("Some invoice text for Carrefour Maadi with enough characters to count as text.", at: pdf)
        let offline = FakeLLM { _, _ in throw LLMError.unreachable("connection refused") }
        let outcome = await service(store, dir, offline).ingest(pdf)
        guard case .failed(let id, _) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(offline.calls.count == 3)
        let inv = try await store.invoice(id)
        #expect(inv.status == .failed && inv.attempts == 3 && inv.lastError?.contains("connection refused") == true)
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.count == 0)
        // AI comes back: the user presses Retry.
        let online = service(store, dir, FakeLLM { _, _ in reply(goodInvoiceJSON) })
        #expect(await online.retry(invoiceID: id) == .confirmed(invoiceID: id))
    }

    @Test func garbageJSONIsRetriedAndOneBadInvoiceDoesNotAffectAnother() async throws {
        let (store, dir) = try await makeStore()
        let good = dir.appendingPathComponent("good.pdf"), bad = dir.appendingPathComponent("bad.pdf")
        try makePDF("GOOD invoice: Carrefour Maadi 14/03/2026 total 1,368.00 EGP rice olive oil", at: good)
        try makePDF("BAD invoice: the model will answer nonsense for this one, always.", at: bad)
        let llm = FakeLLM { msgs, _ in msgs[1].content.contains("BAD") ? reply("I cannot read this, sorry") : reply(goodInvoiceJSON) }
        let svc = service(store, dir, llm)
        async let r1 = svc.ingest(bad)
        async let r2 = svc.ingest(good)
        let (o1, o2) = await (r1, r2)
        guard case .failed = o1 else { Issue.record("bad should fail, got \(o1)"); return }
        guard case .confirmed = o2 else { Issue.record("good should confirm, got \(o2)"); return }
    }

    @Test func embeddingOutageStillIndexesKeywords() async throws {
        let (store, dir) = try await makeStore()
        let pdf = dir.appendingPathComponent("e.pdf")
        try makePDF("Carrefour Maadi invoice with rice and olive oil, total 1,368.00 EGP on 14/03/2026", at: pdf)
        let svc = service(store, dir, FakeLLM(embedFails: true) { _, _ in reply(goodInvoiceJSON) })
        guard case .confirmed(let id) = await svc.ingest(pdf) else { Issue.record("should confirm"); return }
        #expect(try await store.ftsSearch("rice").first?.invoiceID == id)
        #expect(try await store.embeddedChunkCount() == 0)
    }

    @Test func userConfirmsAndRejectsProposedInvoices() async throws {
        let (store, dir) = try await makeStore()
        let pdf = dir.appendingPathComponent("low.pdf")
        try makePDF("Faded receipt, Carrefour Maadi, total 1,368.00 EGP, 14/03/2026", at: pdf)
        let lowConf = goodInvoiceJSON.replacingOccurrences(of: "\"confidence\":0.95", with: "\"confidence\":0.5")
        let outcome = await service(store, dir, FakeLLM { _, _ in reply(lowConf) }).ingest(pdf)
        guard case .needsReview(let id, _) = outcome else { Issue.record("expected review"); return }
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.count == 0)    // excluded until confirmed
        var corrected = try await InvoiceExtractor.parse(json: lowConf, categoryKeys: ["groceries"])
        corrected.totalMinor = 140_000
        try await store.confirmInvoice(id, corrected: corrected)
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 2870)  // 1,400 EGP
        try await store.rejectInvoice(id)
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.count == 0)
        try await store.undoLast()   // undo reject
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.count == 1)
    }
}

@Suite("Assistant")
struct AssistantTests {
    let today = Day(parsing: "2026-11-12")!

    func seeded() async throws -> ExpenseStore {
        let (store, _) = try await makeStore()
        try await store.addExpense(NewExpense(day: d("2026-10-03"), amountMinor: 4500, currency: "USD", categoryKey: "food", vendor: "Cafe"))
        try await store.addExpense(NewExpense(day: d("2026-10-20"), amountMinor: 120_00, currency: "USD", categoryKey: "transport", vendor: "Uber"))
        try await store.addExpense(NewExpense(day: d("2026-11-02"), amountMinor: 30_00, currency: "USD", categoryKey: "food", vendor: "Cafe"))
        return store
    }

    func assistant(_ store: ExpenseStore, _ llm: LLM) async throws -> Assistant {
        Assistant(llm: llm, store: store, search: SearchService(store: store, llm: llm),
                  categoryKeys: try await store.categories().map(\.key), today: today)
    }

    @Test func totalsComeFromTheDatabase() async throws {
        let store = try await seeded()
        let llm = FakeLLM { msgs, i in
            if i == 0 { return callTool("query_expenses", #"{"period":"2026-10","group_by":"category"}"#) }
            let tool = msgs.last!.content
            #expect(tool.contains("\"grand_total\":\"$165.00\""))
            return reply("In October 2026 you spent $165.00: transport $120.00 and food $45.00.")
        }
        let turn = try await assistant(store, llm).ask("How much did I spend last month?")
        #expect(turn.unverifiedNumbers.isEmpty)
        #expect(turn.toolTrace.first?.hasPrefix("query_expenses") == true)
    }

    @Test func inventedNumbersAreFlagged() async throws {
        let store = try await seeded()
        let llm = FakeLLM { _, i in
            i == 0 ? callTool("query_expenses", #"{"period":"2026-10"}"#) : reply("You spent $165.00, about $5.50 per day.")
        }
        let turn = try await assistant(store, llm).ask("October spending?")
        #expect(turn.unverifiedNumbers == ["$5.50"])
    }

    @Test func showChartProducesExactChartData() async throws {
        let store = try await seeded()
        let llm = FakeLLM { _, i in
            i == 0 ? callTool("show_chart", #"{"period":"2026","group_by":"month","chart_type":"bar"}"#) : reply("Here is 2026 by month.")
        }
        let turn = try await assistant(store, llm).ask("اعرض لي مصاريف السنة دي")
        let charts = turn.effects.compactMap { if case .chart(let c) = $0 { return c } else { return nil } }
        #expect(charts.count == 1)
        #expect(charts[0].rows.count == 12)                                   // every month, zeros included
        #expect(charts[0].totalUSDMinor == 19_500)
        #expect(turn.effects.contains(.navigate(.analytics)))
    }

    @Test func writesWaitForConfirmationThenApplyAndUndo() async throws {
        let store = try await seeded()
        let llm = FakeLLM { _, i in
            i == 0 ? callTool("delete_expenses", #"{"expense_ids":[1,2]}"#) : reply("Press Confirm to delete them.")
        }
        let a = try await assistant(store, llm)
        let turn = try await a.ask("delete the first two expenses")
        #expect(turn.pending.count == 1)
        #expect(turn.pending[0].summary == "Delete 2 expense(s) totaling $165.00 (ids 1, 2)")
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 19_500)   // nothing deleted yet
        _ = try await a.commit(turn.pending[0])
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 3000)
        #expect(try await store.auditLog().first?.actor == "ai")
        try await store.undoLast()
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none).first?.usdMinor == 19_500)
    }

    @Test func badWriteArgumentsGoBackToTheModel() async throws {
        let store = try await seeded()
        let llm = FakeLLM { msgs, i in
            if i == 0 { return callTool("split_expense", #"{"expense_id":2,"parts":[{"amount":100,"category":"transport"},{"amount":10,"category":"food"}]}"#) }
            #expect(msgs.last!.content.contains("parts sum to $110.00 but the expense is $120.00"))
            return reply("Those parts don't add up to $120.00. How should I split it?")
        }
        let turn = try await assistant(store, llm).ask("split the uber ride")
        #expect(turn.pending.isEmpty)
        #expect(turn.unverifiedNumbers.isEmpty)
    }

    @Test func searchCitesInvoicesAndAdmitsNotFound() async throws {
        let (store, dir) = try await makeStore()
        let pdf = dir.appendingPathComponent("c.pdf")
        try makePDF("Carrefour Maadi 14/03/2026 Rice 5kg, Olive oil, total 1,368.00 EGP", at: pdf)
        _ = await IngestService(store: store, llm: FakeLLM { _, _ in reply(goodInvoiceJSON) },
                                filesDir: dir.appendingPathComponent("f"), backoff: { _ in }, today: { Day(parsing: "2026-11-12")! }).ingest(pdf)
        let executor = ToolExecutor(store: store, search: SearchService(store: store, llm: nil), today: today)
        let hit = await executor.run(ToolCall(name: "search_invoices", argumentsJSON: #"{"query":"olive oil"}"#))
        #expect(hit.forModel.contains("\"invoice_id\":1"))
        #expect(hit.effects.contains(.citations([1])))
        let miss = await executor.run(ToolCall(name: "search_invoices", argumentsJSON: #"{"query":"laptop"}"#))
        #expect(miss.forModel.contains("No invoice matches"))
    }

    @Test func runawayToolLoopIsBounded() async throws {
        let store = try await seeded()
        let llm = FakeLLM { _, _ in callTool("navigate", #"{"screen":"dashboard"}"#) }
        let turn = try await assistant(store, llm).ask("loop forever")
        #expect(llm.calls.count == 6)
        #expect(turn.text.contains("couldn't finish"))
    }

    @Test func futureDatesAndUnknownToolsAreRejected() async throws {
        let store = try await seeded()
        let ex = ToolExecutor(store: store, search: SearchService(store: store, llm: nil), today: today)
        let r = await ex.run(ToolCall(name: "add_expense", argumentsJSON: #"{"date":"2027-01-01","amount":5,"category":"food"}"#))
        #expect(r.forModel.contains("date is in the future") && r.effects.isEmpty)
        let u = await ex.run(ToolCall(name: "drop_table", argumentsJSON: "{}"))
        #expect(u.forModel.contains("unknown tool"))
    }
}

@Suite("Postgres specifics")
struct PostgresTests {
    @Test func concurrentUploadsOfTheSameFileCreateOneInvoice() async throws {
        let (store, _) = try await makeStore()
        let results = await withTaskGroup(of: Result<Int64, Error>.self) { g in
            for i in 0..<10 {
                g.addTask {
                    do { return .success(try await store.insertPendingInvoice(sha256: "same-hash", filePath: "/tmp/x\(i).pdf", originalName: "x.pdf")) }
                    catch { return .failure(error) }
                }
            }
            var out: [Result<Int64, Error>] = []
            for await r in g { out.append(r) }
            return out
        }
        let winners = results.compactMap { try? $0.get() }
        #expect(winners.count == 1)
        let losers = results.compactMap { r -> Int64? in
            if case .failure(ExpensesError.duplicateFile(let id)) = r { return id }; return nil
        }
        #expect(losers.count == 9 && Set(losers) == Set(winners))
        try await store.dropSchema()
    }

    @Test func hnswVectorSearchRanksTheRightInvoice() async throws {
        let (store, dir) = try await makeStore()
        let llm = FakeLLM { _, _ in reply("{}") }
        let texts = ["laptop charger usb-c 65W", "fresh bread and milk", "taxi ride to the airport"]
        for (i, t) in texts.enumerated() {
            let id = try await store.insertPendingInvoice(sha256: "h\(i)", filePath: dir.appendingPathComponent("\(i).pdf").path, originalName: "\(i).pdf")
            let vec = try await llm.embed([t])[0]
            try await store.replaceChunks(invoiceID: id, chunks: [(t, vec)])
        }
        #expect(try await store.embeddedChunkCount() == 3)
        let q = try await llm.embed(["usb-c laptop charger"])[0]
        #expect(try await store.vectorSearch(q, limit: 1).first?.text == "laptop charger usb-c 65W")
        let hits = try await SearchService(store: store, llm: llm).search("taxi airport", limit: 3)
        #expect(hits.first?.snippet == "taxi ride to the airport")
        try await store.dropSchema()
    }

    @Test func arabicFullTextSearch() async throws {
        let (store, dir) = try await makeStore()
        let id = try await store.insertPendingInvoice(sha256: "ar", filePath: dir.path + "/ar.pdf", originalName: "ar.pdf")
        try await store.replaceChunks(invoiceID: id, chunks: [("فاتورة صيدلية العزبي بنادول ١٠٠ جنيه", nil)])
        #expect(try await store.ftsSearch("بنادول").first?.invoiceID == id)
        #expect(try await store.ftsSearch("laptop").isEmpty)
        try await store.dropSchema()
    }
}

@Suite("Dry-run regressions")
struct DryRunRegressionTests {
    let today = Day(parsing: "2026-11-12")!

    @Test func promptCarriesComputedDateAnchors() async throws {
        let (store, _) = try await makeStore()
        let llm = FakeLLM { msgs, _ in
            let sys = msgs[0].content
            #expect(sys.contains("last month = 2026-10"))
            #expect(sys.contains("yesterday = 2026-11-11"))
            #expect(sys.contains("\"September\" = 2026-09"))
            #expect(sys.contains("last year = 2025"))
            return reply("ok")
        }
        _ = try await Assistant(llm: llm, store: store, search: SearchService(store: store, llm: nil), categoryKeys: ["food"], today: today).ask("hi")
        #expect(Assistant.mostRecent(month: 12, today: today) == "2025-12")
        try await store.dropSchema()
    }

    @Test func replyLanguageIsDecidedByScript() {
        #expect(Assistant.replyLanguage("How much did I spend last month?") == "English")
        #expect(Assistant.replyLanguage("كم صرفت على البقالة في سبتمبر؟") == "Arabic")
        #expect(Assistant.replyLanguage("اعرض expenses السنة") == "Arabic")
    }

    @Test func pendingWritesGetCodeWrittenText() async throws {
        let (store, _) = try await makeStore()
        let llm = FakeLLM { _, i in i == 0 ? callTool("add_expense", #"{"date":"2026-11-11","amount":12,"category":"transport"}"#) : reply("تمت إضافة المصروف!") }
        let turn = try await Assistant(llm: llm, store: store, search: SearchService(store: store, llm: nil), categoryKeys: ["transport"], today: today).ask("add 12 dollars taxi yesterday")
        #expect(turn.text == "Waiting for your confirmation: Add $12.00 for transport on 2026-11-11")
        #expect(try await store.aggregate(ExpenseFilter(), groupBy: .none)[0].count == 0)
        try await store.dropSchema()
    }

    @Test func comparePeriodsComputesTheDifference() async throws {
        let (store, _) = try await makeStore()
        try await store.addExpense(NewExpense(day: d("2026-10-05"), amountMinor: 64350, currency: "USD", categoryKey: "food"))
        try await store.addExpense(NewExpense(day: d("2026-09-05"), amountMinor: 67332, currency: "USD", categoryKey: "food"))
        let ex = ToolExecutor(store: store, search: SearchService(store: store, llm: nil), today: today)
        let r = await ex.run(ToolCall(name: "compare_periods", argumentsJSON: #"{"period_a":"2026-10","period_b":"2026-09"}"#))
        #expect(r.forModel.contains("\"difference_a_minus_b\":\"-$29.82\""))
        #expect(r.forModel.contains("\"percent_change_vs_b\":\"-4.4%\""))
        try await store.dropSchema()
    }

    @Test func citationsKeepOnlyMentionedInvoices() {
        let e = Assistant.filterCitations([.citations([1, 8, 3, 2, 6])], text: "Invoice #1 and Invoice #8 both contain olive oil.")
        #expect(e == [.citations([1, 8])])
        #expect(Assistant.filterCitations([.citations([5, 4])], text: "No laptop found.") == [.citations([5])])
    }
}
