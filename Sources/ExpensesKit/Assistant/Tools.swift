import Foundation

public enum Screen: String, Sendable, Codable, CaseIterable {
    case dashboard, invoices, review, analytics, expenses, settings
}

public enum ChartKind: String, Sendable, Codable, CaseIterable { case bar, line, pie }

public struct ChartSpec: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(title)|\(groupBy.rawValue)|\(from?.iso ?? "")|\(to?.iso ?? "")" }
    public var title: String
    public var kind: ChartKind
    public var groupBy: GroupBy
    public var from: Day?
    public var to: Day?
    public var rows: [AggregateRow]
    public var totalUSDMinor: Int64 { rows.reduce(0) { $0 + $1.usdMinor } }
}

/// A write the AI wants to make. Nothing happens until the user presses Confirm.
public struct PendingAction: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let toolName: String
    public let argumentsJSON: String
    public let summary: String
}

public enum ToolCatalog {
    static let groupEnum = #"["none","day","month","year","category","vendor"]"#
    static func categoryEnum(_ keys: [String]) -> String { "[" + keys.map { "\"\($0)\"" }.joined(separator: ",") + "]" }

    static func periodProps() -> String {
        #"""
        "period": {"type":"string","description":"Shortcut range: a year 'YYYY', a month 'YYYY-MM' or a day 'YYYY-MM-DD'"},
        "from": {"type":"string","description":"Start day YYYY-MM-DD (inclusive)"},
        "to": {"type":"string","description":"End day YYYY-MM-DD (inclusive)"}
        """#
    }

    public static func all(categoryKeys keys: [String]) -> [ToolSpec] {
        let cats = categoryEnum(keys)
        return [
            ToolSpec(name: "query_expenses",
                     description: "Exact totals of confirmed expenses in USD, optionally grouped by day, month, year, category or vendor. Use for ANY question about amounts or spending.",
                     parametersJSON: #"{"type":"object","properties":{\#(periodProps()),"group_by":{"type":"string","enum":\#(groupEnum)},"category":{"type":"string","enum":\#(cats)},"vendor":{"type":"string"}}}"#,
                     mutates: false),
            ToolSpec(name: "show_chart",
                     description: "Show a chart of spending in the app (bar, line or pie). Use when the user asks to see, view, plot or graph expenses.",
                     parametersJSON: #"{"type":"object","properties":{\#(periodProps()),"group_by":{"type":"string","enum":\#(groupEnum)},"chart_type":{"type":"string","enum":["bar","line","pie"]},"category":{"type":"string","enum":\#(cats)},"vendor":{"type":"string"},"title":{"type":"string"}},"required":["group_by"]}"#,
                     mutates: false),
            ToolSpec(name: "compare_periods",
                     description: "Compare total spending between two periods (difference and percent change computed exactly). Use for 'compare', 'more or less than', 'vs'.",
                     parametersJSON: #"{"type":"object","properties":{"period_a":{"type":"string","description":"YYYY, YYYY-MM or YYYY-MM-DD"},"period_b":{"type":"string","description":"YYYY, YYYY-MM or YYYY-MM-DD"},"category":{"type":"string","enum":\#(cats)}},"required":["period_a","period_b"]}"#,
                     mutates: false),
            ToolSpec(name: "list_expenses",
                     description: "List individual expenses (newest first) with their ids, for showing or before editing/deleting.",
                     parametersJSON: #"{"type":"object","properties":{\#(periodProps()),"category":{"type":"string","enum":\#(cats)},"vendor":{"type":"string"},"limit":{"type":"integer","description":"max 50"}}}"#,
                     mutates: false),
            ToolSpec(name: "search_invoices",
                     description: "Semantic + keyword search over invoice contents (items, vendors, notes). Use for 'which invoice…', 'did I buy…', 'find the receipt…'.",
                     parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#,
                     mutates: false),
            ToolSpec(name: "get_invoice",
                     description: "Full details of ONE invoice by id: every line item with quantity, unit price and line amount, subtotal, tax, total, date, vendor, status and review reasons. Use for questions about an invoice's items, quantities, prices or contents.",
                     parametersJSON: #"{"type":"object","properties":{"invoice_id":{"type":"integer"}},"required":["invoice_id"]}"#,
                     mutates: false),
            ToolSpec(name: "open_invoice", description: "Open an invoice in the app by id.",
                     parametersJSON: #"{"type":"object","properties":{"invoice_id":{"type":"integer"}},"required":["invoice_id"]}"#,
                     mutates: false),
            ToolSpec(name: "navigate", description: "Switch the app to a screen.",
                     parametersJSON: #"{"type":"object","properties":{"screen":{"type":"string","enum":["dashboard","invoices","review","analytics","expenses","settings"]}},"required":["screen"]}"#,
                     mutates: false),
            ToolSpec(name: "add_expense", description: "Add a manual expense (no invoice).",
                     parametersJSON: #"{"type":"object","properties":{"date":{"type":"string","description":"YYYY-MM-DD"},"amount":{"type":"number"},"currency":{"type":"string","description":"ISO code, default USD"},"category":{"type":"string","enum":\#(cats)},"vendor":{"type":"string"},"note":{"type":"string"}},"required":["date","amount","category"]}"#,
                     mutates: true),
            ToolSpec(name: "edit_expense", description: "Change fields of one expense by id.",
                     parametersJSON: #"{"type":"object","properties":{"expense_id":{"type":"integer"},"date":{"type":"string"},"amount":{"type":"number"},"currency":{"type":"string"},"category":{"type":"string","enum":\#(cats)},"vendor":{"type":"string"},"note":{"type":"string"}},"required":["expense_id"]}"#,
                     mutates: true),
            ToolSpec(name: "delete_expenses", description: "Delete expenses by id (soft delete, undoable).",
                     parametersJSON: #"{"type":"object","properties":{"expense_ids":{"type":"array","items":{"type":"integer"}}},"required":["expense_ids"]}"#,
                     mutates: true),
            ToolSpec(name: "split_expense", description: "Split one expense into parts with different categories; parts must sum to the original amount (in its currency).",
                     parametersJSON: #"{"type":"object","properties":{"expense_id":{"type":"integer"},"parts":{"type":"array","items":{"type":"object","properties":{"amount":{"type":"number"},"category":{"type":"string","enum":\#(cats)}},"required":["amount","category"]}}},"required":["expense_id","parts"]}"#,
                     mutates: true),
            ToolSpec(name: "confirm_invoice", description: "Confirm a proposed invoice so it counts in totals.",
                     parametersJSON: #"{"type":"object","properties":{"invoice_id":{"type":"integer"}},"required":["invoice_id"]}"#,
                     mutates: true),
            ToolSpec(name: "set_exchange_rate", description: "Set how many USD one unit of a currency is worth, from a date onward.",
                     parametersJSON: #"{"type":"object","properties":{"currency":{"type":"string"},"usd_per_unit":{"type":"number"},"date":{"type":"string"}},"required":["currency","usd_per_unit"]}"#,
                     mutates: true),
            ToolSpec(name: "undo_last", description: "Undo the most recent change.",
                     parametersJSON: #"{"type":"object","properties":{}}"#, mutates: true),
        ]
    }
}

/// Runs tool calls against the store. Read tools run immediately; write tools are
/// validated and turned into a PendingAction that only `commit` executes.
public struct ToolExecutor: Sendable {
    let store: ExpenseStore
    let search: SearchService
    let today: Day

    public init(store: ExpenseStore, search: SearchService, today: Day = .today) {
        self.store = store; self.search = search; self.today = today
    }

    public enum Effect: Sendable, Hashable {
        case chart(ChartSpec)
        case table(title: String, rows: [AggregateRow])
        case expenses([Expense])
        case navigate(Screen)
        case openInvoice(Int64)
        case citations([Int64])
        case pending(PendingAction)
    }

    public struct Result: Sendable {
        public var forModel: String
        public var effects: [Effect] = []
    }

    struct Args {
        let o: [String: Any]
        init(_ json: String) { o = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:] }
        func str(_ k: String) -> String? {
            if let s = o[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            if let n = o[k] as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ k: String) -> Int64? {
            if let n = o[k] as? NSNumber { return n.int64Value }
            if let s = o[k] as? String { return Int64(Money.westernizeDigits(s).filter(\.isNumber)) }
            return nil
        }
        func decimal(_ k: String) -> Decimal? {
            if let n = o[k] as? NSNumber { return Decimal(string: n.stringValue) }
            if let s = o[k] as? String { return Money.parseAmount(s) }
            return nil
        }
    }

    func filter(_ a: Args) throws -> ExpenseFilter {
        var f = ExpenseFilter(categoryKey: a.str("category"), vendor: a.str("vendor"))
        if let p = a.str("period") {
            guard let r = Day.range(loose: p) else { throw ExpensesError.invalid("period '\(p)' must be YYYY, YYYY-MM or YYYY-MM-DD") }
            f.from = r.lowerBound; f.to = r.upperBound
        }
        if let s = a.str("from") { guard let r = Day.range(loose: s) else { throw ExpensesError.invalid("bad from date '\(s)'") }; f.from = r.lowerBound }
        if let s = a.str("to") { guard let r = Day.range(loose: s) else { throw ExpensesError.invalid("bad to date '\(s)'") }; f.to = r.upperBound }
        if let from = f.from, let to = f.to, from > to { throw ExpensesError.invalid("from is after to") }
        return f
    }

    static func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func describe(_ f: ExpenseFilter) -> String {
        var s = "\(f.from?.iso ?? "beginning") to \(f.to?.iso ?? "today")"
        if let c = f.categoryKey { s += ", category \(c)" }
        if let v = f.vendor { s += ", vendor \(v)" }
        return s
    }

    public func run(_ call: ToolCall) async -> Result {
        let a = Args(call.argumentsJSON)
        do {
            switch call.name {
            case "query_expenses", "show_chart":
                let f = try filter(a)
                let g = GroupBy(rawValue: a.str("group_by") ?? "none") ?? .none
                let rows = try await store.aggregate(f, groupBy: g, fillGaps: call.name == "show_chart")
                let total = rows.reduce(Int64(0)) { $0 + $1.usdMinor }
                let count = rows.reduce(0) { $0 + $1.count }
                let shown = rows.filter { call.name == "show_chart" || $0.count > 0 }
                var payload: [String: Any] = [
                    "range": describe(f), "group_by": g.rawValue, "currency": "USD",
                    "grand_total": Money.format(total), "expense_count": count,
                    "rows": shown.prefix(40).map { ["label": $0.label, "total": Money.format($0.usdMinor), "count": $0.count] },
                ]
                if shown.count > 40 { payload["note"] = "showing first 40 of \(shown.count) rows" }
                var effects: [Effect] = []
                if call.name == "show_chart" {
                    let kind = ChartKind(rawValue: a.str("chart_type") ?? "") ?? (g == .category || g == .vendor ? .pie : .bar)
                    let title = a.str("title") ?? "Spending by \(g.rawValue), \(describe(f))"
                    effects.append(.chart(ChartSpec(title: title, kind: kind, groupBy: g, from: f.from, to: f.to, rows: rows)))
                    effects.append(.navigate(.analytics))
                    payload["shown_to_user"] = true
                } else if g != .none {
                    effects.append(.table(title: "By \(g.rawValue), \(describe(f))", rows: rows.filter { $0.count > 0 }))
                }
                return Result(forModel: Self.json(payload), effects: effects)

            case "compare_periods":
                guard let pa = a.str("period_a"), let ra = Day.range(loose: pa), let pb = a.str("period_b"), let rb = Day.range(loose: pb) else {
                    throw ExpensesError.invalid("period_a and period_b must be YYYY, YYYY-MM or YYYY-MM-DD")
                }
                let cat = a.str("category")
                let ta = try await store.aggregate(ExpenseFilter(from: ra.lowerBound, to: ra.upperBound, categoryKey: cat), groupBy: .none)[0]
                let tb = try await store.aggregate(ExpenseFilter(from: rb.lowerBound, to: rb.upperBound, categoryKey: cat), groupBy: .none)[0]
                let diff = ta.usdMinor - tb.usdMinor
                var payload: [String: Any] = [
                    "period_a": pa, "total_a": Money.format(ta.usdMinor), "count_a": ta.count,
                    "period_b": pb, "total_b": Money.format(tb.usdMinor), "count_b": tb.count,
                    "difference_a_minus_b": Money.format(diff),
                    "direction": diff > 0 ? "A is higher" : diff < 0 ? "A is lower" : "equal",
                ]
                if tb.usdMinor > 0 { payload["percent_change_vs_b"] = String(format: "%+.1f%%", Double(diff) / Double(tb.usdMinor) * 100) }
                let rows = [AggregateRow(key: pa, label: pa, usdMinor: ta.usdMinor, count: ta.count),
                            AggregateRow(key: pb, label: pb, usdMinor: tb.usdMinor, count: tb.count)]
                return Result(forModel: Self.json(payload), effects: [.table(title: "\(pa) vs \(pb)", rows: rows)])

            case "list_expenses":
                let f = try filter(a)
                let limit = Int(min(max(a.int("limit") ?? 20, 1), 50))
                let page = try await store.listExpenses(f, limit: limit)
                let rows = page.rows.map { e -> [String: Any] in
                    var o: [String: Any] = ["expense_id": e.id, "date": e.day.iso, "category": e.categoryKey,
                                            "amount": Money.format(e.amountMinor, currency: e.currency), "usd": Money.format(e.usdMinor)]
                    if let v = e.vendor { o["vendor"] = v }
                    if let i = e.invoiceID { o["invoice_id"] = i }
                    return o
                }
                return Result(forModel: Self.json(["range": describe(f), "expenses": rows, "more_available": page.next != nil]),
                              effects: [.expenses(page.rows)])

            case "search_invoices":
                guard let q = a.str("query") else { throw ExpensesError.invalid("query is required") }
                let hits = try await search.search(q, limit: 5)
                if hits.isEmpty { return Result(forModel: Self.json(["results": [], "note": "No invoice matches. Say it was not found."])) }
                var results: [[String: Any]] = []
                for h in hits {
                    var o: [String: Any] = ["invoice_id": h.invoiceID, "excerpt": h.snippet]
                    if let inv = try? await store.invoice(h.invoiceID) {
                        o["status"] = inv.status.rawValue
                        if let v = inv.vendor { o["vendor"] = v }
                        o["date"] = inv.day?.iso ?? "not on the invoice (unknown)"
                        if let t = inv.totalMinor, let c = inv.currency { o["total"] = Money.format(t, currency: c) }
                    }
                    results.append(o)
                }
                return Result(forModel: Self.json(["results": results, "instruction": "Cite invoices as [#id]. Only state facts present in excerpts/fields. For items, quantities or prices call get_invoice."]),
                              effects: [.citations(hits.map(\.invoiceID))])

            case "get_invoice":
                guard let id = a.int("invoice_id") else { throw ExpensesError.invalid("invoice_id is required") }
                let inv = try await store.invoice(id)
                let cur = inv.currency ?? Money.base
                let missing = "not on the invoice (unknown)"
                var payload: [String: Any] = [
                    "invoice_id": inv.id, "status": inv.status.rawValue,
                    "counts_in_totals": inv.status == .confirmed,
                    "vendor": inv.vendor ?? missing,
                    "date": inv.day?.iso ?? missing,
                    "currency": inv.currency ?? missing,
                    "total": inv.totalMinor.map { Money.format($0, currency: cur) } ?? missing,
                    "line_items": inv.lineItems.map { li -> [String: Any] in
                        var o: [String: Any] = ["item": li.description, "quantity": li.quantity.truncatingRemainder(dividingBy: 1) == 0 ? Int(li.quantity) : li.quantity,
                                                "line_amount": Money.format(li.totalMinor, currency: cur)]
                        if let u = li.unitMinor { o["unit_price"] = Money.format(u, currency: cur) }
                        else if li.quantity > 1 { o["unit_price"] = "not printed" }
                        return o
                    },
                    "items_sum": Money.format(inv.lineItems.reduce(0) { $0 + $1.totalMinor }, currency: cur),
                    "instruction": "Report fields exactly as given. If a field says unknown, say it is missing; never fill it from the conversation.",
                ]
                if !inv.reviewReasons.isEmpty, inv.status != .confirmed { payload["review_reasons"] = inv.reviewReasons }
                return Result(forModel: Self.json(payload), effects: [.citations([id])])

            case "open_invoice":
                guard let id = a.int("invoice_id") else { throw ExpensesError.invalid("invoice_id is required") }
                let inv = try await store.invoice(id)
                return Result(forModel: Self.json(["opened": id, "status": inv.status.rawValue]), effects: [.openInvoice(id), .navigate(.invoices)])

            case "navigate":
                guard let s = a.str("screen"), let screen = Screen(rawValue: s) else { throw ExpensesError.invalid("unknown screen") }
                return Result(forModel: Self.json(["navigated_to": screen.rawValue]), effects: [.navigate(screen)])

            default:
                // Write tools: validate now (so the model can fix bad args), execute only on confirm.
                let summary = try await validateWrite(call.name, a)
                let pending = PendingAction(toolName: call.name, argumentsJSON: call.argumentsJSON, summary: summary)
                return Result(forModel: Self.json(["status": "awaiting_user_confirmation", "summary": summary,
                                                   "instruction": "Not done yet. Tell the user to press Confirm to apply it."]),
                              effects: [.pending(pending)])
            }
        } catch {
            return Result(forModel: Self.json(["error": "\(error)"]))
        }
    }

    func newExpense(_ a: Args) throws -> NewExpense {
        guard let ds = a.str("date"), let day = Day(parsing: ds) else { throw ExpensesError.invalid("date must be YYYY-MM-DD") }
        guard day <= today else { throw ExpensesError.invalid("date is in the future") }
        guard let amount = a.decimal("amount"), amount > 0 else { throw ExpensesError.invalid("amount must be a positive number") }
        let currency = Money.normalizeCurrency(a.str("currency") ?? "USD") ?? "USD"
        return NewExpense(day: day, amountMinor: Money.toMinor(amount, currency: currency), currency: currency,
                          categoryKey: a.str("category") ?? "other", vendor: a.str("vendor"), note: a.str("note"))
    }

    func validateWrite(_ name: String, _ a: Args) async throws -> String {
        switch name {
        case "add_expense":
            let e = try newExpense(a)
            _ = try await store.rateE6(currency: e.currency, on: e.day)
            return "Add \(Money.format(e.amountMinor, currency: e.currency)) for \(e.categoryKey)\(e.vendor.map { " at \($0)" } ?? "") on \(e.day.iso)"
        case "edit_expense":
            guard let id = a.int("expense_id") else { throw ExpensesError.invalid("expense_id is required") }
            let before = try await store.expense(id)
            var changes: [String] = []
            if let d = a.str("date") { changes.append("date → \(d)") }
            if let amt = a.decimal("amount") { changes.append("amount → \(amt) \(a.str("currency") ?? before.currency)") }
            if let c = a.str("category") { changes.append("category → \(c)") }
            if let v = a.str("vendor") { changes.append("vendor → \(v)") }
            if let n = a.str("note") { changes.append("note → \(n)") }
            guard !changes.isEmpty else { throw ExpensesError.invalid("nothing to change") }
            return "Edit expense #\(id) (\(Money.format(before.amountMinor, currency: before.currency)), \(before.day.iso)): " + changes.joined(separator: ", ")
        case "delete_expenses":
            let ids = ((a.o["expense_ids"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.int64Value ?? Int64("\($0)") }
            guard !ids.isEmpty else { throw ExpensesError.invalid("expense_ids is empty") }
            var total: Int64 = 0
            for id in ids { total += try await store.expense(id).usdMinor }
            return "Delete \(ids.count) expense(s) totaling \(Money.format(total)) (ids \(ids.map(String.init).joined(separator: ", ")))"
        case "split_expense":
            guard let id = a.int("expense_id") else { throw ExpensesError.invalid("expense_id is required") }
            let e = try await store.expense(id)
            let parts = try splitParts(a, currency: e.currency)
            let sum = parts.reduce(Int64(0)) { $0 + $1.amountMinor }
            guard sum == e.amountMinor else {
                throw ExpensesError.invalid("parts sum to \(Money.format(sum, currency: e.currency)) but the expense is \(Money.format(e.amountMinor, currency: e.currency))")
            }
            return "Split expense #\(id) (\(Money.format(e.amountMinor, currency: e.currency))) into " +
                parts.map { "\(Money.format($0.amountMinor, currency: e.currency)) \($0.categoryKey)" }.joined(separator: " + ")
        case "confirm_invoice":
            guard let id = a.int("invoice_id") else { throw ExpensesError.invalid("invoice_id is required") }
            let inv = try await store.invoice(id)
            guard inv.status == .proposed else { throw ExpensesError.invalid("invoice #\(id) is \(inv.status.rawValue), not awaiting review") }
            return "Confirm invoice #\(id)\(inv.vendor.map { " from \($0)" } ?? "")\(inv.totalMinor.flatMap { t in inv.currency.map { ", \(Money.format(t, currency: $0))" } } ?? "")"
        case "set_exchange_rate":
            guard let c = Money.normalizeCurrency(a.str("currency")) else { throw ExpensesError.invalid("unknown currency") }
            guard let r = a.decimal("usd_per_unit"), r > 0 else { throw ExpensesError.invalid("usd_per_unit must be positive") }
            let day = a.str("date").flatMap { Day(parsing: $0) } ?? today
            return "Set 1 \(c) = \(r) USD from \(day.iso) (affects new expenses only; existing ones keep their frozen rate)"
        case "undo_last":
            guard let last = try await store.auditLog(limit: 20).first(where: { !$0.undone }) else { throw ExpensesError.nothingToUndo }
            return "Undo: \(last.summary)"
        default:
            throw ExpensesError.invalid("unknown tool \(name)")
        }
    }

    func splitParts(_ a: Args, currency: String) throws -> [(amountMinor: Int64, categoryKey: String)] {
        let raw = (a.o["parts"] as? [[String: Any]]) ?? []
        return try raw.map { p in
            let amt: Decimal? = (p["amount"] as? NSNumber).flatMap { Decimal(string: $0.stringValue) } ?? (p["amount"] as? String).flatMap(Money.parseAmount)
            guard let amt, amt > 0 else { throw ExpensesError.invalid("each part needs a positive amount") }
            return (Money.toMinor(amt, currency: currency), (p["category"] as? String) ?? "other")
        }
    }

    /// Executes a confirmed write. Runs in one transaction inside the store; recorded in the audit log.
    public func commit(_ p: PendingAction) async throws -> String {
        let a = Args(p.argumentsJSON)
        _ = try await validateWrite(p.toolName, a)   // re-validate: data may have changed since the card was shown
        switch p.toolName {
        case "add_expense":
            let id = try await store.addExpense(try newExpense(a), actor: "ai")
            return "Added expense #\(id)."
        case "edit_expense":
            let id = a.int("expense_id")!
            let before = try await store.expense(id)
            let currency = a.str("currency").flatMap { Money.normalizeCurrency($0) }
            var edit = ExpenseEdit(day: a.str("date").flatMap { Day(parsing: $0) }, currency: currency,
                                   categoryKey: a.str("category"), vendor: a.str("vendor"), note: a.str("note"))
            if let amt = a.decimal("amount") { edit.amountMinor = Money.toMinor(amt, currency: currency ?? before.currency) }
            try await store.editExpense(id, edit, actor: "ai")
            return "Updated expense #\(id)."
        case "delete_expenses":
            let ids = ((a.o["expense_ids"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.int64Value ?? Int64("\($0)") }
            try await store.deleteExpenses(ids, actor: "ai")
            return "Deleted \(ids.count) expense(s). You can undo this."
        case "split_expense":
            let id = a.int("expense_id")!
            let e = try await store.expense(id)
            let ids = try await store.splitExpense(id, parts: try splitParts(a, currency: e.currency), actor: "ai")
            return "Split into expenses \(ids.map { "#\($0)" }.joined(separator: ", "))."
        case "confirm_invoice":
            let id = a.int("invoice_id")!
            try await store.confirmInvoice(id, actor: "ai")
            return "Invoice #\(id) confirmed."
        case "set_exchange_rate":
            let c = Money.normalizeCurrency(a.str("currency"))!
            try await store.setRate(currency: c, day: a.str("date").flatMap { Day(parsing: $0) } ?? today, usdPerUnit: a.decimal("usd_per_unit")!)
            return "Rate saved for \(c)."
        case "undo_last":
            return try await store.undoLast()
        default:
            throw ExpensesError.invalid("unknown tool \(p.toolName)")
        }
    }
}
