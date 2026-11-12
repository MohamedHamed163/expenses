import Foundation
import SwiftUI
import ExpensesKit

struct ChatItem: Identifiable, Hashable {
    enum Role { case user, assistant, notice }
    enum ActionState: Hashable { case waiting, done(String), cancelled, failed(String) }
    let id = UUID()
    var role: Role
    var text: String
    var charts: [ChartSpec] = []
    var tables: [ToolTable] = []
    var pending: [PendingAction] = []
    var actionStates: [UUID: ActionState] = [:]
    var citations: [Int64] = []
    var unverified: [String] = []
    var trace: [String] = []
    var viaVoice = false
}

struct ToolTable: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var rows: [AggregateRow]
}

struct AnalyticsState: Hashable {
    var from: Day? = Day.today.adding(months: -11).startOfMonth
    var to: Day? = Day.today
    var groupBy: GroupBy = .month
    var kind: ChartKind = .bar
    var category: String? = nil
}

struct DashboardData {
    var thisMonth: Int64 = 0
    var lastMonth: Int64 = 0
    var monthBefore: Int64 = 0
    var yearToDate: Int64 = 0
    var months: [AggregateRow] = []
    var categories: [AggregateRow] = []
    var recent: [Expense] = []
}

@MainActor @Observable
final class AppModel {
    private(set) var store: ExpenseStore!
    let llm = OllamaLLM()
    private(set) var ingest: IngestService!
    private(set) var search: SearchService!
    private(set) var assistant: Assistant!
    /// nil while connecting; set when Postgres is unreachable.
    var databaseError: String?
    var ready = false

    var screen: Screen = .dashboard
    var aiOnline = false
    var categories: [ExpensesKit.Category] = []
    var counts: [InvoiceStatus: Int] = [:]
    var invoices: [Invoice] = []
    var invoiceFilter: InvoiceStatus? = nil
    var selectedInvoiceID: Int64?
    var importing: [String] = []
    var dashboard = DashboardData()
    var analytics = AnalyticsState()
    var analyticsRows: [AggregateRow] = []
    var chat: [ChatItem] = []
    var thinking = false
    var toast: String?
    var showChat = true
    var revision = 0

    init() {
        chat = []
    }

    func start() async {
        databaseError = nil
        do {
            store = try await ExpenseStore(config: .fromEnvironment())
        } catch {
            databaseError = "\(error)"
            return
        }
        ingest = IngestService(store: store, llm: llm, filesDir: ExpenseStore.defaultURL().appendingPathComponent("files"))
        search = SearchService(store: store, llm: llm)
        categories = (try? await store.categories()) ?? []
        assistant = Assistant(llm: llm, store: store, search: search, categoryKeys: categories.map(\.key))
        await assistant.setLogURL(ExpenseStore.defaultURL().appendingPathComponent("logs/wallet-turns.jsonl"))
        ready = true
        await refreshAll()
        await applyLaunchHooks()
        aiOnline = await llm.isReachable()
        if aiOnline {
            let results = await ingest.processPending()
            if !results.isEmpty { await refreshAll(); flash("Processed \(results.count) invoice(s) left from last time") }
        }
    }

    /// Debug/demo hooks used to capture report screenshots:
    /// EXPENSES_START_SCREEN=analytics, EXPENSES_SELECT_INVOICE=5, EXPENSES_AUTOASK="question".
    func applyLaunchHooks() async {
        let env = ProcessInfo.processInfo.environment
        if let s = env["EXPENSES_START_SCREEN"], let screen = Screen(rawValue: s) {
            if screen == .review { invoiceFilter = .proposed; await refreshAll() }
            self.screen = screen
        }
        if let i = env["EXPENSES_SELECT_INVOICE"].flatMap(Int64.init) { selectedInvoiceID = i; self.screen = .invoices }
        if let q = env["EXPENSES_AUTOASK"] {
            aiOnline = await llm.isReachable()
            for part in q.components(separatedBy: " || ") { await send(part) }
        }
    }

    func categoryName(_ key: String) -> String {
        categories.first { $0.key == key }?.nameEN ?? key.capitalized
    }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if toast == s { toast = nil } }
    }

    // MARK: - Loading

    func refreshAll() async {
        revision += 1
        counts = (try? await store.invoiceCounts()) ?? [:]
        invoices = (try? await store.invoices(status: invoiceFilter)) ?? []
        await loadDashboard()
        await loadAnalytics()
    }

    func loadDashboard() async {
        let t = Day.today
        func sum(_ f: ExpenseFilter) async -> Int64 { (try? await store.aggregate(f, groupBy: .none).first?.usdMinor) ?? 0 }
        dashboard.thisMonth = await sum(ExpenseFilter(from: t.startOfMonth, to: t))
        let lm = t.startOfMonth.adding(months: -1)
        dashboard.lastMonth = await sum(ExpenseFilter(from: lm, to: lm.endOfMonth))
        let mb = lm.adding(months: -1)
        dashboard.monthBefore = await sum(ExpenseFilter(from: mb, to: mb.endOfMonth))
        dashboard.yearToDate = await sum(ExpenseFilter(from: t.startOfYear, to: t))
        dashboard.months = (try? await store.aggregate(ExpenseFilter(from: t.adding(months: -11).startOfMonth, to: t), groupBy: .month)) ?? []
        dashboard.categories = (try? await store.aggregate(ExpenseFilter(from: t.startOfYear, to: t), groupBy: .category)) ?? []
        dashboard.recent = (try? await store.listExpenses(limit: 8).rows) ?? []
    }

    func loadAnalytics() async {
        let f = ExpenseFilter(from: analytics.from, to: analytics.to, categoryKey: analytics.category)
        analyticsRows = (try? await store.aggregate(f, groupBy: analytics.groupBy)) ?? []
    }

    // MARK: - Invoices

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            importing.append(url.lastPathComponent)
            let outcome = await ingest.ingest(url)
            importing.removeAll { $0 == url.lastPathComponent }
            await assistant?.noteAppEvent("A new invoice was imported (\(url.lastPathComponent)): \(outcome).")
            switch outcome {
            case .confirmed(let id): flash("✓ Invoice #\(id) added")
            case .needsReview(let id, _): flash("Invoice #\(id) needs review"); selectedInvoiceID = id
            case .duplicateFile(let id): flash("Already imported as invoice #\(id)")
            case .failed(_, let e): flash(e.contains("unreachable") || e.contains("offline") ? "AI offline: saved, will retry" : "Failed: \(e.prefix(80))")
            }
            await refreshAll()
        }
        aiOnline = await llm.isReachable()
    }

    func retry(_ id: Int64) async {
        importing.append("invoice #\(id)")
        _ = await ingest.retry(invoiceID: id)
        importing.removeAll { $0 == "invoice #\(id)" }
        await refreshAll()
    }

    func confirm(_ id: Int64, corrected: ExtractedInvoice?) async {
        do {
            try await store.confirmInvoice(id, corrected: corrected)
            flash("Invoice #\(id) confirmed")
            await assistant?.noteAppEvent("The user confirmed invoice #\(id) in the review screen\(corrected?.day.map { " with date \($0.iso)" } ?? ""); it now counts in totals.")
        }
        catch { flash("\(error)") }
        await refreshAll()
    }

    func reject(_ id: Int64) async {
        do {
            try await store.rejectInvoice(id); flash("Invoice #\(id) rejected")
            await assistant?.noteAppEvent("The user rejected invoice #\(id); it no longer counts in totals.")
        } catch { flash("\(error)") }
        await refreshAll()
    }

    func undo() async {
        do {
            let msg = try await store.undoLast()
            flash(msg)
            await assistant?.noteAppEvent("The user pressed Undo: \(msg).")
        } catch { flash("\(error)") }
        await refreshAll()
    }

    // MARK: - Chat

    func newConversation() {
        chat = []
        Task { await assistant.reset() }
    }

    func send(_ text: String, viaVoice: Bool = false) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        var userItem = ChatItem(role: .user, text: q)
        userItem.viaVoice = viaVoice
        chat.append(userItem)
        thinking = true
        defer { thinking = false }
        do {
            let turn = try await assistant.ask(q)
            aiOnline = true
            var item = ChatItem(role: .assistant, text: turn.text, unverified: turn.unverifiedNumbers, trace: turn.toolTrace)
            for e in turn.effects { apply(e, to: &item) }
            chat.append(item)
        } catch {
            aiOnline = await llm.isReachable()
            chat.append(ChatItem(role: .notice, text: aiOnline ? "Error: \(error)" : "AI offline (Ollama isn't running). Charts, lists and manual entry still work."))
        }
    }

    private func apply(_ e: ToolExecutor.Effect, to item: inout ChatItem) {
        switch e {
        case .chart(let c):
            item.charts.append(c)
            analytics = AnalyticsState(from: c.from, to: c.to, groupBy: c.groupBy, kind: c.kind, category: nil)
            analyticsRows = c.rows
        case .table(let title, let rows): item.tables.append(ToolTable(title: title, rows: rows))
        case .expenses: break
        case .navigate(let s): screen = s
        case .openInvoice(let id): selectedInvoiceID = id; invoiceFilter = nil; screen = .invoices
        case .citations(let ids): item.citations = ids
        case .pending(let p): item.pending.append(p); item.actionStates[p.id] = .waiting
        }
    }

    func resolve(_ action: PendingAction, in itemID: UUID, confirm: Bool) async {
        guard let idx = chat.firstIndex(where: { $0.id == itemID }) else { return }
        if !confirm {
            await assistant.decline(action)
            chat[idx].actionStates[action.id] = .cancelled
            return
        }
        do {
            let msg = try await assistant.commit(action)
            chat[idx].actionStates[action.id] = .done(msg)
        } catch {
            chat[idx].actionStates[action.id] = .failed("\(error)")
        }
        await refreshAll()
    }

    func openCitation(_ id: Int64) {
        selectedInvoiceID = id
        invoiceFilter = nil
        screen = .invoices
        Task { await refreshAll() }
    }
}
