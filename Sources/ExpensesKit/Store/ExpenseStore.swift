import Foundation

/// All data lives in Postgres 17 + pgvector. Each public method leases one
/// pooled connection; every write runs inside BEGIN … COMMIT on that connection,
/// so a failure rolls the whole operation back. Concurrent readers are handled
/// by Postgres MVCC; conflicting writers by row locks and UNIQUE constraints.
public final class ExpenseStore: Sendable {
    let db: PGDatabase
    public var config: PGConfig { db.config }

    public init(config: PGConfig = .fromEnvironment()) async throws {
        db = PGDatabase(config)
        try await Schema.migrate(db)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Expenses", isDirectory: true)
    }

    // MARK: - Reference data

    public func categories() async throws -> [Category] {
        try await db.read { c in
            try await c.query("SELECT id, key, name_en, name_ar FROM categories ORDER BY id").map {
                Category(id: $0.int("id")!, key: $0.text("key")!, nameEN: $0.text("name_en")!, nameAR: $0.text("name_ar")!)
            }
        }
    }

    func categoryID(_ c: PGConn, _ key: String?) async throws -> Int64 {
        let k = (key ?? "other").lowercased()
        if let id = try await c.scalar("SELECT id FROM categories WHERE key = ?", [.text(k)]) { return id }
        return try await c.scalar("SELECT id FROM categories WHERE key = 'other'")!
    }

    public static func normalizeVendor(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Upsert-by-normalized-name; race-safe via ON CONFLICT.
    func vendorID(_ c: PGConn, _ name: String?) async throws -> Int64? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let norm = Self.normalizeVendor(trimmed)
        guard !norm.isEmpty else { return nil }
        return try await c.scalar("""
            INSERT INTO vendors(name, norm_name) VALUES (?, ?)
            ON CONFLICT (norm_name) DO UPDATE SET norm_name = EXCLUDED.norm_name RETURNING id
            """, [.text(trimmed), .text(norm)])
    }

    static func opt(_ v: Int64?) -> PGValue { v.map { .int($0) } ?? .null }
    static func opt(_ v: String?) -> PGValue { v.map { .text($0) } ?? .null }

    // MARK: - FX

    public func rateE6(currency: String, on day: Day) async throws -> Int64 {
        try await db.read { try await self.rateE6($0, currency: currency, on: day) }
    }

    func rateE6(_ c: PGConn, currency: String, on day: Day) async throws -> Int64 {
        let cur = currency.uppercased()
        if cur == Money.base { return 1_000_000 }
        if let r = try await c.scalar("SELECT rate_e6 FROM fx_rates WHERE currency = ? AND day <= ? ORDER BY day DESC LIMIT 1", [.text(cur), .int(Int64(day.value))]) { return r }
        if let r = try await c.scalar("SELECT rate_e6 FROM fx_rates WHERE currency = ? ORDER BY day ASC LIMIT 1", [.text(cur)]) { return r }
        throw ExpensesError.noRate(currency: cur)
    }

    public func setRate(currency: String, day: Day, usdPerUnit: Decimal) async throws {
        try await db.read { c in
            try await c.run("""
                INSERT INTO fx_rates(currency, day, rate_e6) VALUES (?,?,?)
                ON CONFLICT (currency, day) DO UPDATE SET rate_e6 = EXCLUDED.rate_e6
                """, [.text(currency.uppercased()), .int(Int64(day.value)), .int(Money.rateE6(fromUSDPerUnit: usdPerUnit))])
        }
    }

    public func rates() async throws -> [(currency: String, day: Day, rateE6: Int64)] {
        try await db.read { c in
            try await c.query("SELECT currency, day, rate_e6 FROM fx_rates ORDER BY currency, day DESC").compactMap {
                guard let d = Day(Int($0.int("day")!)) else { return nil }
                return ($0.text("currency")!, d, $0.int("rate_e6")!)
            }
        }
    }

    // MARK: - Invoices

    /// Step 1 of ingestion: record the file before any AI work, so nothing is lost if the AI is down.
    /// Two concurrent uploads of the same file: the UNIQUE constraint lets exactly one win.
    public func insertPendingInvoice(sha256: String, filePath: String, originalName: String) async throws -> Int64 {
        try await db.read { c in
            if let id = try await c.scalar("""
                INSERT INTO invoices(file_sha256, file_path, original_name, status) VALUES (?,?,?, 'pending')
                ON CONFLICT (file_sha256) DO NOTHING RETURNING id
                """, [.text(sha256), .text(filePath), .text(originalName)]) { return id }
            let existing = try await c.scalar("SELECT id FROM invoices WHERE file_sha256 = ?", [.text(sha256)]) ?? -1
            throw ExpensesError.duplicateFile(existingInvoiceID: existing)
        }
    }

    public func recordAttemptFailure(invoiceID: Int64, error: String, maxAttempts: Int) async throws -> Int {
        try await db.read { c in
            Int(try await c.scalar("""
                UPDATE invoices SET attempts = attempts + 1, last_error = ?, updated_at = now(),
                  status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE 'pending' END
                WHERE id = ? RETURNING attempts
                """, [.text(error), .int(Int64(maxAttempts)), .int(invoiceID)]) ?? 0)
        }
    }

    public func resetForRetry(invoiceID: Int64) async throws {
        try await db.read { c in
            try await c.run("UPDATE invoices SET status = 'pending', attempts = 0, last_error = NULL WHERE id = ? AND status IN ('failed','pending')", [.int(invoiceID)])
        }
    }

    /// A different invoice with the same vendor, day and total.
    public func likelyDuplicate(of invoiceID: Int64, vendor: String?, day: Day?, totalMinor: Int64?, currency: String?) async throws -> Int64? {
        guard let vendor, let day, let totalMinor else { return nil }
        return try await db.read { c in
            try await c.scalar("""
                SELECT i.id FROM invoices i JOIN vendors v ON v.id = i.vendor_id
                WHERE v.norm_name = ? AND i.issue_day = ? AND i.total_minor = ? AND i.currency IS NOT DISTINCT FROM ?
                  AND i.id <> ? AND i.status IN ('proposed','confirmed')
                ORDER BY i.id LIMIT 1
                """, [.text(Self.normalizeVendor(vendor)), .int(Int64(day.value)), .int(totalMinor), Self.opt(currency), .int(invoiceID)])
        }
    }

    /// Step 2: save the extraction. If `autoConfirm`, the expense is created in the same transaction.
    public func applyExtraction(invoiceID: Int64, extracted e: ExtractedInvoice, ocrText: String, rawJSON: String,
                                reasons: [String], duplicateOf: Int64?, autoConfirm: Bool) async throws {
        try await db.transaction { c in
            try await self.writeExtractedFields(c, invoiceID: invoiceID, e)
            let reasonsJSON = String(data: try JSONEncoder().encode(reasons), encoding: .utf8)!
            try await c.run("""
                UPDATE invoices SET ocr_text = ?, extraction_json = ?::jsonb, review_reasons = ?::jsonb, duplicate_of = ?,
                  status = 'proposed', last_error = NULL, updated_at = now() WHERE id = ?
                """, [.text(ocrText), .text(rawJSON), .text(reasonsJSON), Self.opt(duplicateOf), .int(invoiceID)])
            if autoConfirm { _ = try await self.confirmInside(c, invoiceID: invoiceID, actor: "auto") }
        }
    }

    private func writeExtractedFields(_ c: PGConn, invoiceID: Int64, _ e: ExtractedInvoice) async throws {
        let vid = try await vendorID(c, e.vendor)
        try await c.run("""
            UPDATE invoices SET vendor_id = ?, invoice_number = ?, issue_day = ?, currency = ?, subtotal_minor = ?,
              tax_minor = ?, total_minor = ?, category_key = ?, confidence = ? WHERE id = ?
            """, [Self.opt(vid), Self.opt(e.invoiceNumber), Self.opt(e.day.map { Int64($0.value) }), Self.opt(e.currency),
                  Self.opt(e.subtotalMinor), Self.opt(e.taxMinor), Self.opt(e.totalMinor), Self.opt(e.categoryKey),
                  .double(e.confidence), .int(invoiceID)])
        try await c.run("DELETE FROM line_items WHERE invoice_id = ?", [.int(invoiceID)])
        for li in e.lineItems {
            try await c.run("INSERT INTO line_items(invoice_id, description, quantity, unit_minor, total_minor) VALUES (?,?,?,?,?)",
                            [.int(invoiceID), .text(li.description), .double(li.quantity), Self.opt(li.unitMinor), .int(li.totalMinor)])
        }
    }

    /// User confirms a proposed invoice, optionally with corrected fields.
    @discardableResult
    public func confirmInvoice(_ invoiceID: Int64, corrected: ExtractedInvoice? = nil, actor: String = "user") async throws -> Int64 {
        try await db.transaction { c in
            if let corrected { try await self.writeExtractedFields(c, invoiceID: invoiceID, corrected) }
            return try await self.confirmInside(c, invoiceID: invoiceID, actor: actor)
        }
    }

    private func confirmInside(_ c: PGConn, invoiceID: Int64, actor: String) async throws -> Int64 {
        // FOR UPDATE: two confirms of the same invoice can't both create an expense.
        guard let row = try await c.query("""
            SELECT i.status, i.issue_day, i.currency, i.total_minor, i.category_key, v.name AS vendor
            FROM invoices i LEFT JOIN vendors v ON v.id = i.vendor_id WHERE i.id = ? FOR UPDATE OF i
            """, [.int(invoiceID)]).first else { throw ExpensesError.notFound("invoice #\(invoiceID)") }
        guard row.text("status") != "confirmed" else { throw ExpensesError.invalid("invoice #\(invoiceID) is already confirmed") }
        guard let dayInt = row.int("issue_day"), let day = Day(Int(dayInt)) else { throw ExpensesError.invalid("invoice has no date") }
        guard let currency = row.text("currency") else { throw ExpensesError.invalid("invoice has no currency") }
        guard let total = row.int("total_minor") else { throw ExpensesError.invalid("invoice has no total") }
        let expenseID = try await insertExpenseRow(c, NewExpense(day: day, amountMinor: total, currency: currency,
                                                                 categoryKey: row.text("category_key") ?? "other",
                                                                 vendor: row.text("vendor")), invoiceID: invoiceID)
        let previous = row.text("status") ?? "proposed"
        try await c.run("UPDATE invoices SET status = 'confirmed', updated_at = now() WHERE id = ?", [.int(invoiceID)])
        try await audit(c, action: "confirm_invoice", actor: actor,
                        summary: "Confirmed invoice #\(invoiceID): \(Money.format(total, currency: currency))",
                        undo: UndoPlan(softDelete: [expenseID], invoiceStatus: [.init(id: invoiceID, status: previous)]))
        return expenseID
    }

    public func rejectInvoice(_ invoiceID: Int64, actor: String = "user") async throws {
        try await db.transaction { c in
            guard let status = try await c.scalarText("SELECT status FROM invoices WHERE id = ? FOR UPDATE", [.int(invoiceID)]) else {
                throw ExpensesError.notFound("invoice #\(invoiceID)")
            }
            let ids = try await c.query("SELECT id FROM expenses WHERE invoice_id = ? AND deleted_at IS NULL", [.int(invoiceID)]).compactMap { $0.int("id") }
            try await self.softDelete(c, ids)
            try await c.run("UPDATE invoices SET status = 'rejected', updated_at = now() WHERE id = ?", [.int(invoiceID)])
            try await self.audit(c, action: "reject_invoice", actor: actor, summary: "Rejected invoice #\(invoiceID)",
                                 undo: UndoPlan(undelete: ids, invoiceStatus: [.init(id: invoiceID, status: status)]))
        }
    }

    public func invoices(status: InvoiceStatus? = nil, limit: Int = 200) async throws -> [Invoice] {
        try await db.read { c in
            var sql = "SELECT i.*, i.review_reasons::text AS reasons, v.name AS vendor FROM invoices i LEFT JOIN vendors v ON v.id = i.vendor_id"
            var params: [PGValue] = []
            if let status { sql += " WHERE i.status = ?"; params.append(.text(status.rawValue)) }
            sql += " ORDER BY i.id DESC LIMIT ?"
            params.append(.int(Int64(limit)))
            var out: [Invoice] = []
            for r in try await c.query(sql, params) { out.append(try await self.invoice(c, from: r, withItems: false)) }
            return out
        }
    }

    public func invoice(_ id: Int64) async throws -> Invoice {
        try await db.read { c in
            guard let r = try await c.query("SELECT i.*, i.review_reasons::text AS reasons, v.name AS vendor FROM invoices i LEFT JOIN vendors v ON v.id = i.vendor_id WHERE i.id = ?", [.int(id)]).first else {
                throw ExpensesError.notFound("invoice #\(id)")
            }
            return try await self.invoice(c, from: r, withItems: true)
        }
    }

    private func invoice(_ c: PGConn, from r: PGRow, withItems: Bool) async throws -> Invoice {
        let id = r.int("id")!
        let reasons = (try? JSONDecoder().decode([String].self, from: Data((r.text("reasons") ?? "[]").utf8))) ?? []
        var items: [LineItem] = []
        if withItems {
            items = try await c.query("SELECT * FROM line_items WHERE invoice_id = ? ORDER BY id", [.int(id)]).map {
                LineItem(description: $0.text("description") ?? "", quantity: $0.double("quantity") ?? 1,
                         unitMinor: $0.int("unit_minor"), totalMinor: $0.int("total_minor") ?? 0)
            }
        }
        return Invoice(id: id, status: InvoiceStatus(rawValue: r.text("status") ?? "pending") ?? .pending,
                       filePath: r.text("file_path") ?? "", originalName: r.text("original_name") ?? "",
                       vendor: r.text("vendor"), day: r.int("issue_day").flatMap { Day(Int($0)) },
                       currency: r.text("currency"), totalMinor: r.int("total_minor"), categoryKey: r.text("category_key"),
                       confidence: r.double("confidence"), reviewReasons: reasons, duplicateOf: r.int("duplicate_of"),
                       attempts: Int(r.int("attempts") ?? 0), lastError: r.text("last_error"), ocrText: r.text("ocr_text"),
                       lineItems: items)
    }

    public func pendingInvoiceIDs() async throws -> [Int64] {
        try await db.read { try await $0.query("SELECT id FROM invoices WHERE status = 'pending' ORDER BY id").compactMap { $0.int("id") } }
    }

    public func invoiceCounts() async throws -> [InvoiceStatus: Int] {
        try await db.read { c in
            var out: [InvoiceStatus: Int] = [:]
            for r in try await c.query("SELECT status, count(*) AS n FROM invoices GROUP BY status") {
                if let s = InvoiceStatus(rawValue: r.text("status") ?? "") { out[s] = Int(r.int("n") ?? 0) }
            }
            return out
        }
    }

    // MARK: - Expenses (all writes audited, all undoable)

    private func insertExpenseRow(_ c: PGConn, _ e: NewExpense, invoiceID: Int64?) async throws -> Int64 {
        guard e.amountMinor > 0 else { throw ExpensesError.invalid("amount must be positive") }
        let currency = e.currency.uppercased()
        let rate = try await rateE6(c, currency: currency, on: e.day)
        let usd = Money.usdMinor(amountMinor: e.amountMinor, currency: currency, rateE6: rate)
        return try await c.scalar("""
            INSERT INTO expenses(invoice_id, day, category_id, vendor_id, amount_minor, currency, fx_rate_e6, usd_minor, note)
            VALUES (?,?,?,?,?,?,?,?,?) RETURNING id
            """, [Self.opt(invoiceID), .int(Int64(e.day.value)), .int(try await categoryID(c, e.categoryKey)),
                  Self.opt(try await vendorID(c, e.vendor)), .int(e.amountMinor), .text(currency), .int(rate),
                  .int(usd), Self.opt(e.note)])!
    }

    @discardableResult
    public func addExpense(_ e: NewExpense, actor: String = "user") async throws -> Int64 {
        try await db.transaction { c in
            let id = try await self.insertExpenseRow(c, e, invoiceID: nil)
            try await self.audit(c, action: "add_expense", actor: actor,
                                 summary: "Added \(Money.format(e.amountMinor, currency: e.currency)) \(e.categoryKey) on \(e.day)",
                                 undo: UndoPlan(softDelete: [id]))
            return id
        }
    }

    public func editExpense(_ id: Int64, _ edit: ExpenseEdit, actor: String = "user") async throws {
        try await db.transaction { c in
            let before = try await self.expense(c, id, lock: true)
            let day = edit.day ?? before.day
            let currency = (edit.currency ?? before.currency).uppercased()
            let amount = edit.amountMinor ?? before.amountMinor
            guard amount > 0 else { throw ExpensesError.invalid("amount must be positive") }
            // Re-freeze the rate only if the date or currency changed.
            let rate = (edit.day != nil || edit.currency != nil) ? try await self.rateE6(c, currency: currency, on: day) : before.fxRateE6
            let usd = Money.usdMinor(amountMinor: amount, currency: currency, rateE6: rate)
            try await c.run("""
                UPDATE expenses SET day = ?, amount_minor = ?, currency = ?, fx_rate_e6 = ?, usd_minor = ?,
                  category_id = ?, vendor_id = ?, note = ? WHERE id = ?
                """, [.int(Int64(day.value)), .int(amount), .text(currency), .int(rate), .int(usd),
                      .int(try await self.categoryID(c, edit.categoryKey ?? before.categoryKey)),
                      Self.opt(try await self.vendorID(c, edit.vendor ?? before.vendor)),
                      Self.opt(edit.note ?? before.note), .int(id)])
            try await self.audit(c, action: "edit_expense", actor: actor, summary: "Edited expense #\(id)", undo: UndoPlan(restore: [before]))
        }
    }

    public func deleteExpenses(_ ids: [Int64], actor: String = "user") async throws {
        guard !ids.isEmpty else { return }
        try await db.transaction { c in
            var total: Int64 = 0
            for id in ids { total += try await self.expense(c, id, lock: true).usdMinor }
            try await self.softDelete(c, ids)
            try await self.audit(c, action: "delete_expenses", actor: actor,
                                 summary: "Deleted \(ids.count) expense(s), \(Money.format(total))", undo: UndoPlan(undelete: ids))
        }
    }

    /// Splits one expense into parts that must add up exactly to the original amount.
    public func splitExpense(_ id: Int64, parts: [(amountMinor: Int64, categoryKey: String)], actor: String = "user") async throws -> [Int64] {
        try await db.transaction { c in
            let original = try await self.expense(c, id, lock: true)
            guard parts.count >= 2 else { throw ExpensesError.invalid("a split needs at least 2 parts") }
            let sum = parts.reduce(Int64(0)) { $0 + $1.amountMinor }
            guard sum == original.amountMinor else {
                throw ExpensesError.invalid("parts add up to \(Money.format(sum, currency: original.currency)), expected \(Money.format(original.amountMinor, currency: original.currency))")
            }
            try await self.softDelete(c, [id])
            var newIDs: [Int64] = []
            for p in parts {
                let usd = Money.usdMinor(amountMinor: p.amountMinor, currency: original.currency, rateE6: original.fxRateE6)
                newIDs.append(try await c.scalar("""
                    INSERT INTO expenses(invoice_id, day, category_id, vendor_id, amount_minor, currency, fx_rate_e6, usd_minor, note)
                    SELECT invoice_id, day, ?, vendor_id, ?, currency, fx_rate_e6, ?, note FROM expenses WHERE id = ? RETURNING id
                    """, [.int(try await self.categoryID(c, p.categoryKey)), .int(p.amountMinor), .int(usd), .int(id)])!)
            }
            try await self.audit(c, action: "split_expense", actor: actor, summary: "Split expense #\(id) into \(parts.count)",
                                 undo: UndoPlan(softDelete: newIDs, undelete: [id]))
            return newIDs
        }
    }

    private func softDelete(_ c: PGConn, _ ids: [Int64]) async throws {
        for id in ids { try await c.run("UPDATE expenses SET deleted_at = now() WHERE id = ? AND deleted_at IS NULL", [.int(id)]) }
    }

    static let expenseSelect = """
        SELECT e.id, e.invoice_id, e.day, e.amount_minor, e.currency, e.fx_rate_e6, e.usd_minor, e.note,
               c.key AS category_key, v.name AS vendor
        FROM expenses e JOIN categories c ON c.id = e.category_id LEFT JOIN vendors v ON v.id = e.vendor_id
        """

    public func expense(_ id: Int64) async throws -> Expense {
        try await db.read { try await self.expense($0, id, lock: false) }
    }

    private func expense(_ c: PGConn, _ id: Int64, lock: Bool) async throws -> Expense {
        guard let r = try await c.query(Self.expenseSelect + " WHERE e.id = ? AND e.deleted_at IS NULL" + (lock ? " FOR UPDATE OF e" : ""), [.int(id)]).first else {
            throw ExpensesError.notFound("expense #\(id)")
        }
        return Self.expense(from: r)
    }

    static func expense(from r: PGRow) -> Expense {
        Expense(id: r.int("id")!, invoiceID: r.int("invoice_id"), day: Day(Int(r.int("day")!))!,
                categoryKey: r.text("category_key") ?? "other", vendor: r.text("vendor"),
                amountMinor: r.int("amount_minor")!, currency: r.text("currency")!, fxRateE6: r.int("fx_rate_e6")!,
                usdMinor: r.int("usd_minor")!, note: r.text("note"))
    }

    /// Keyset pagination: pass the last row's cursor to get the next page.
    public func listExpenses(_ f: ExpenseFilter = .init(), limit: Int = 50, after cursor: PageCursor? = nil) async throws -> (rows: [Expense], next: PageCursor?) {
        try await db.read { c in
            var (whereSQL, params) = try await self.filterSQL(c, f)
            if let cursor {
                whereSQL += " AND (e.day, e.id) < (?, ?)"
                params += [.int(Int64(cursor.day)), .int(cursor.id)]
            }
            let rows = try await c.query(Self.expenseSelect + " WHERE \(whereSQL) ORDER BY e.day DESC, e.id DESC LIMIT ?",
                                         params + [.int(Int64(limit))]).map(Self.expense(from:))
            let next = rows.count == limit ? rows.last.map { PageCursor(day: $0.day.value, id: $0.id) } : nil
            return (rows, next)
        }
    }

    private func filterSQL(_ c: PGConn, _ f: ExpenseFilter) async throws -> (String, [PGValue]) {
        var clauses = ["e.deleted_at IS NULL"]
        var params: [PGValue] = []
        if let from = f.from { clauses.append("e.day >= ?"); params.append(.int(Int64(from.value))) }
        if let to = f.to { clauses.append("e.day <= ?"); params.append(.int(Int64(to.value))) }
        if let k = f.categoryKey { clauses.append("e.category_id = ?"); params.append(.int(try await categoryID(c, k))) }
        if let v = f.vendor, !v.isEmpty {
            clauses.append("e.vendor_id IN (SELECT id FROM vendors WHERE norm_name LIKE ?)")
            params.append(.text("%\(Self.normalizeVendor(v))%"))
        }
        return (clauses.joined(separator: " AND "), params)
    }

    /// Every number the app or the AI shows comes from here. The LLM never adds numbers.
    public func aggregate(_ f: ExpenseFilter, groupBy: GroupBy, fillGaps: Bool = true) async throws -> [AggregateRow] {
        var rows: [AggregateRow] = try await db.read { c in
            let (whereSQL, params) = try await self.filterSQL(c, f)
            let keyExpr: String, labelExpr: String, join: String
            switch groupBy {
            case .none: keyExpr = "'total'"; labelExpr = "'Total'"; join = ""
            case .day: keyExpr = "e.day::text"; labelExpr = "e.day::text"; join = ""
            case .month: keyExpr = "(e.day / 100)::text"; labelExpr = "(e.day / 100)::text"; join = ""
            case .year: keyExpr = "(e.day / 10000)::text"; labelExpr = "(e.day / 10000)::text"; join = ""
            case .category: keyExpr = "c.key"; labelExpr = "c.name_en"; join = "JOIN categories c ON c.id = e.category_id"
            case .vendor: keyExpr = "COALESCE(v.norm_name, '')"; labelExpr = "COALESCE(v.name, '(no vendor)')"; join = "LEFT JOIN vendors v ON v.id = e.vendor_id"
            }
            let order = [.category, .vendor].contains(groupBy) ? "total DESC" : "1"
            return try await c.query("""
                SELECT \(keyExpr) AS k, min(\(labelExpr)) AS label, COALESCE(SUM(e.usd_minor), 0)::bigint AS total, COUNT(e.id) AS n
                FROM expenses e \(join) WHERE \(whereSQL) GROUP BY 1 ORDER BY \(order)
                """, params).map { r in
                let key = r.text("k") ?? ""
                return AggregateRow(key: key, label: Self.label(for: r.text("label") ?? key, groupBy: groupBy),
                                    usdMinor: r.int("total") ?? 0, count: Int(r.int("n") ?? 0))
            }
        }
        if groupBy == .none && rows.isEmpty {
            // An empty period is "$0.00 across 0 expenses", not "no answer".
            rows = [AggregateRow(key: "total", label: "Total", usdMinor: 0, count: 0)]
        }
        if fillGaps, let from = f.from, let to = f.to, [.day, .month].contains(groupBy) {
            rows = Self.fillGaps(rows, from: from, to: to, groupBy: groupBy)
        }
        return rows
    }

    static func label(for key: String, groupBy: GroupBy) -> String {
        switch groupBy {
        case .day: return Day(Int(key) ?? 0)?.iso ?? key
        case .month:
            guard let v = Int(key) else { return key }
            let f = DateFormatter(); f.dateFormat = "MMM yyyy"; f.locale = Locale(identifier: "en_US"); f.timeZone = TimeZone(identifier: "UTC")
            return Day(year: v / 100, month: v % 100, day: 1).map { f.string(from: $0.date) } ?? key
        default: return key
        }
    }

    /// Zero rows for empty days/months so charts show gaps honestly. Capped at 400 points.
    static func fillGaps(_ rows: [AggregateRow], from: Day, to: Day, groupBy: GroupBy) -> [AggregateRow] {
        var byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        var out: [AggregateRow] = []
        var cursor = groupBy == .month ? from.startOfMonth : from
        while cursor <= to, out.count < 400 {
            let key = groupBy == .month ? String(cursor.value / 100) : String(cursor.value)
            out.append(byKey.removeValue(forKey: key) ?? AggregateRow(key: key, label: label(for: key, groupBy: groupBy), usdMinor: 0, count: 0))
            cursor = groupBy == .month ? cursor.adding(months: 1) : cursor.adding(days: 1)
        }
        return out
    }

    // MARK: - Audit + undo

    struct UndoPlan: Codable {
        struct InvoiceStatusChange: Codable { let id: Int64; let status: String }
        var softDelete: [Int64] = []
        var undelete: [Int64] = []
        var restore: [Expense] = []
        var invoiceStatus: [InvoiceStatusChange] = []
    }

    private func audit(_ c: PGConn, action: String, actor: String, summary: String, undo: UndoPlan) async throws {
        let json = String(data: try JSONEncoder().encode(undo), encoding: .utf8)!
        try await c.run("INSERT INTO audit_log(action, actor, summary, undo_json) VALUES (?,?,?,?::jsonb)",
                        [.text(action), .text(actor), .text(summary), .text(json)])
    }

    public func auditLog(limit: Int = 50) async throws -> [AuditEntry] {
        try await db.read { c in
            try await c.query("SELECT id, action, actor, summary, undone, extract(epoch FROM created_at)::float8 AS ts FROM audit_log ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map {
                AuditEntry(id: $0.int("id")!, action: $0.text("action")!, actor: $0.text("actor")!, summary: $0.text("summary")!,
                           undone: $0.bool("undone") ?? false, createdAt: Date(timeIntervalSince1970: $0.double("ts") ?? 0))
            }
        }
    }

    /// Reverses the most recent not-yet-undone change, atomically. The row lock
    /// stops two concurrent undos from reversing the same change twice.
    @discardableResult
    public func undoLast() async throws -> String {
        try await db.transaction { c in
            guard let row = try await c.query("SELECT id, summary, undo_json::text AS undo FROM audit_log WHERE NOT undone ORDER BY id DESC LIMIT 1 FOR UPDATE").first else {
                throw ExpensesError.nothingToUndo
            }
            let plan = try JSONDecoder().decode(UndoPlan.self, from: Data(row.text("undo")!.utf8))
            try await self.softDelete(c, plan.softDelete)
            for id in plan.undelete { try await c.run("UPDATE expenses SET deleted_at = NULL WHERE id = ?", [.int(id)]) }
            for e in plan.restore {
                try await c.run("""
                    UPDATE expenses SET day = ?, amount_minor = ?, currency = ?, fx_rate_e6 = ?, usd_minor = ?,
                      category_id = ?, vendor_id = ?, note = ? WHERE id = ?
                    """, [.int(Int64(e.day.value)), .int(e.amountMinor), .text(e.currency), .int(e.fxRateE6), .int(e.usdMinor),
                          .int(try await self.categoryID(c, e.categoryKey)), Self.opt(try await self.vendorID(c, e.vendor)),
                          Self.opt(e.note), .int(e.id)])
            }
            for s in plan.invoiceStatus {
                try await c.run("UPDATE invoices SET status = ? WHERE id = ?", [.text(s.status), .int(s.id)])
            }
            try await c.run("UPDATE audit_log SET undone = true WHERE id = ?", [.int(row.int("id")!)])
            return "Undid: \(row.text("summary") ?? "")"
        }
    }

    // MARK: - RAG chunks (pgvector + full-text, one table, one transaction)

    static func vectorLiteral(_ v: [Float]) -> String {
        "[" + Vectors.l2normalize(v).map { String(format: "%.6f", $0) }.joined(separator: ",") + "]"
    }

    public func replaceChunks(invoiceID: Int64, chunks: [(text: String, embedding: [Float]?)]) async throws {
        try await db.transaction { c in
            try await c.run("DELETE FROM chunks WHERE invoice_id = ?", [.int(invoiceID)])
            for ch in chunks {
                let emb: PGValue = ch.embedding.flatMap { $0.count == Schema.embeddingDim ? .text(Self.vectorLiteral($0)) : nil } ?? .null
                try await c.run("INSERT INTO chunks(invoice_id, text, embedding) VALUES (?, ?, ?::vector)", [.int(invoiceID), .text(ch.text), emb])
            }
        }
    }

    public struct ChunkHit: Sendable, Hashable {
        public let chunkID: Int64
        public let invoiceID: Int64
        public let text: String
        public let rank: Int
    }

    /// Keyword search over the generated tsvector (GIN index). Any token may match.
    public func ftsSearch(_ query: String, limit: Int = 20) async throws -> [ChunkHit] {
        let tokens = Money.westernizeDigits(query).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return [] }
        let tsquery = tokens.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: " | ")
        return try await db.read { c in
            try await c.query("""
                SELECT ch.id, ch.invoice_id, ch.text FROM chunks ch JOIN invoices i ON i.id = ch.invoice_id
                WHERE ch.tsv @@ to_tsquery('simple', ?) AND i.status <> 'rejected'
                ORDER BY ts_rank_cd(ch.tsv, to_tsquery('simple', ?)) DESC, ch.id LIMIT ?
                """, [.text(tsquery), .text(tsquery), .int(Int64(limit))]).enumerated().map { i, r in
                ChunkHit(chunkID: r.int("id")!, invoiceID: r.int("invoice_id")!, text: r.text("text")!, rank: i + 1)
            }
        }
    }

    /// Approximate nearest neighbours by cosine distance using the HNSW index.
    public func vectorSearch(_ embedding: [Float], limit: Int = 20) async throws -> [ChunkHit] {
        guard embedding.count == Schema.embeddingDim else { return [] }
        return try await db.read { c in
            try await c.run("SET hnsw.ef_search = 64")
            return try await c.query("""
                SELECT ch.id, ch.invoice_id, ch.text FROM chunks ch JOIN invoices i ON i.id = ch.invoice_id
                WHERE ch.embedding IS NOT NULL AND i.status <> 'rejected'
                ORDER BY ch.embedding <=> ?::vector LIMIT ?
                """, [.text(Self.vectorLiteral(embedding)), .int(Int64(limit))]).enumerated().map { i, r in
                ChunkHit(chunkID: r.int("id")!, invoiceID: r.int("invoice_id")!, text: r.text("text")!, rank: i + 1)
            }
        }
    }

    public func embeddedChunkCount() async throws -> Int {
        try await db.read { Int(try await $0.scalar("SELECT count(*) FROM chunks WHERE embedding IS NOT NULL") ?? 0) }
    }

    // MARK: - Settings

    public func setting(_ key: String) async throws -> String? {
        try await db.read { try await $0.scalarText("SELECT value FROM settings WHERE key = ?", [.text(key)]) }
    }
    public func setSetting(_ key: String, _ value: String) async throws {
        try await db.read { try await $0.run("INSERT INTO settings(key, value) VALUES (?,?) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value", [.text(key), .text(value)]) }
    }

    // MARK: - Benchmark seeding + diagnostics

    /// Inserts `count` synthetic USD expenses server-side with generate_series.
    public func seedSynthetic(count: Int, from: Day, days: Int) async throws {
        try await db.read { c in
            for i in 0..<200 { _ = try await self.vendorID(c, "Vendor \(i)") }
            try await c.run("""
                INSERT INTO expenses(day, category_id, vendor_id, amount_minor, currency, fx_rate_e6, usd_minor)
                SELECT to_char(?::date + (random() * ?)::int, 'YYYYMMDD')::bigint,
                       (SELECT min(id) FROM categories) + (random() * 11)::int,
                       (SELECT min(id) FROM vendors) + (random() * 199)::int,
                       a, 'USD', 1000000, a
                FROM (SELECT 100 + (random() * 50000)::bigint AS a FROM generate_series(1, ?)) s
                """, [.text(from.iso), .int(Int64(days - 1)), .int(Int64(count))])
            try await c.run("VACUUM ANALYZE expenses")
        }
    }

    public func explain(_ sql: String) async throws -> [String] {
        try await db.read { try await $0.query("EXPLAIN " + sql).compactMap { $0.text("QUERY PLAN") } }
    }

    /// Drops this store's schema (tests only).
    public func dropSchema() async throws {
        guard config.schema != "public" else { return }
        try await db.read { try await $0.run("DROP SCHEMA IF EXISTS \"\(self.config.schema)\" CASCADE") }
    }
}
