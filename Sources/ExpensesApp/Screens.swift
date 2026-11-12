import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ExpensesKit

// MARK: - Dashboard

struct DashboardView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let d = model.dashboard
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatCard(title: "This month", value: Money.format(d.thisMonth), subtitle: "so far, day \(Day.today.dayOfMonth)", systemImage: "calendar")
                    StatCard(title: "Last month", value: Money.format(d.lastMonth), subtitle: delta(d.lastMonth, d.monthBefore).map { "\($0) vs month before" }, systemImage: "calendar.badge.clock")
                    StatCard(title: "Year to date", value: Money.format(d.yearToDate), systemImage: "chart.line.uptrend.xyaxis")
                    StatCard(title: "Needs review", value: "\(model.counts[.proposed] ?? 0)",
                             subtitle: (model.counts[.failed] ?? 0) + (model.counts[.pending] ?? 0) > 0 ? "\((model.counts[.failed] ?? 0) + (model.counts[.pending] ?? 0)) waiting for AI" : nil,
                             systemImage: "exclamationmark.bubble")
                        .onTapGesture { model.invoiceFilter = .proposed; model.screen = .invoices; Task { await model.refreshAll() } }
                }
                GroupBox("Last 12 months") { SpendChart(rows: d.months, kind: .bar, height: 220).padding(.top, 6) }
                HStack(alignment: .top, spacing: 12) {
                    GroupBox("This year by category") { SpendChart(rows: d.categories, kind: .pie, height: 220).padding(.top, 6) }
                    GroupBox("Recent") {
                        VStack(spacing: 0) {
                            ForEach(d.recent) { e in ExpenseRow(expense: e).padding(.vertical, 5); Divider() }
                            if d.recent.isEmpty { Text("Drop invoices on the Invoices screen to get started.").foregroundStyle(.secondary).padding() }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }

    func delta(_ now: Int64, _ before: Int64) -> String? {
        guard before > 0 else { return nil }
        let pct = Double(now - before) / Double(before) * 100
        return String(format: "%@%.0f%%", pct >= 0 ? "+" : "", pct)
    }
}

struct ExpenseRow: View {
    @Environment(AppModel.self) var model
    let expense: Expense
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.vendor ?? model.categoryName(expense.categoryKey)).lineLimit(1)
                Text("\(expense.day.iso) · \(model.categoryName(expense.categoryKey))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(expense.usdMinor)).monospacedDigit()
                if expense.currency != "USD" {
                    Text(Money.format(expense.amountMinor, currency: expense.currency)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Invoices

struct InvoicesView: View {
    @Environment(AppModel.self) var model
    @State private var showImporter = false
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $model.invoiceFilter) {
                    Text("All").tag(InvoiceStatus?.none)
                    Text("Needs review (\(model.counts[.proposed] ?? 0))").tag(InvoiceStatus?.some(.proposed))
                    Text("Confirmed").tag(InvoiceStatus?.some(.confirmed))
                    Text("Failed").tag(InvoiceStatus?.some(.failed))
                }
                .pickerStyle(.segmented).labelsHidden().padding(10)
                .onChange(of: model.invoiceFilter) { Task { await model.refreshAll() } }
                List(selection: $model.selectedInvoiceID) {
                    ForEach(model.importing, id: \.self) { name in
                        HStack { ProgressView().controlSize(.small); Text("Reading \(name)…").foregroundStyle(.secondary) }
                    }
                    ForEach(model.invoices) { inv in InvoiceListRow(invoice: inv).tag(inv.id) }
                }
                dropZone
            }
            .frame(minWidth: 260, idealWidth: 320)
            Group {
                if let id = model.selectedInvoiceID {
                    InvoiceDetailView(invoiceID: id).id("\(id)-\(model.revision)")
                } else {
                    ContentUnavailableView("Select an invoice", systemImage: "doc.text.magnifyingglass", description: Text("Or drop PDFs and photos on the left."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Invoices")
        .toolbar { Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await model.importFiles(urls) } }
        }
    }

    var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.title2)
            Text("Drop invoices here (PDF, photo, scan)").font(.callout)
            Text("Arabic + English · read on this Mac").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.5)))
        .padding(10)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                await model.importFiles(urls)
            }
            return true
        }
    }
}

struct StatusBadge: View {
    let status: InvoiceStatus
    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .confirmed: ("Confirmed", .green)
        case .proposed: ("Needs review", .orange)
        case .pending: ("Waiting for AI", .blue)
        case .failed: ("Failed", .red)
        case .rejected: ("Rejected", .gray)
        }
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

struct InvoiceListRow: View {
    let invoice: Invoice
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(invoice.vendor ?? invoice.originalName).lineLimit(1)
                HStack(spacing: 6) {
                    Text("#\(invoice.id)").foregroundStyle(.secondary)
                    if let d = invoice.day { Text(d.iso).foregroundStyle(.secondary) }
                    StatusBadge(status: invoice.status)
                }.font(.caption)
            }
            Spacer()
            if let t = invoice.totalMinor, let c = invoice.currency {
                Text(Money.format(t, currency: c)).monospacedDigit().font(.callout)
            }
        }
        .padding(.vertical, 2)
    }
}

struct InvoiceDetailView: View {
    @Environment(AppModel.self) var model
    let invoiceID: Int64
    @State private var invoice: Invoice?
    @State private var vendor = ""
    @State private var date = ""
    @State private var currency = ""
    @State private var total = ""
    @State private var category = "other"
    @State private var showText = false

    var body: some View {
        Group {
            if let inv = invoice {
                HSplitView {
                    Preview(path: inv.filePath).frame(minWidth: 160, idealWidth: 300)
                    ScrollView { form(inv).padding(16) }.frame(minWidth: 260)
                }
            } else { ProgressView() }
        }
        .task { await load() }
    }

    func load() async {
        guard let inv = try? await model.store.invoice(invoiceID) else { return }
        invoice = inv
        vendor = inv.vendor ?? ""
        date = inv.day?.iso ?? ""
        currency = inv.currency ?? ""
        total = inv.totalMinor.map { "\(Money.toMajor($0, currency: inv.currency ?? "USD"))" } ?? ""
        category = inv.categoryKey ?? "other"
    }

    @ViewBuilder func form(_ inv: Invoice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Invoice #\(inv.id)").font(.title3.bold()); StatusBadge(status: inv.status); Spacer() }
            Text(inv.originalName).font(.caption).foregroundStyle(.secondary)
            if !inv.reviewReasons.isEmpty && inv.status != .confirmed {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(inv.reviewReasons, id: \.self) { r in Label(r, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                }
            }
            if let err = inv.lastError, inv.status == .failed || inv.status == .pending {
                Label("\(err.prefix(200))", systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }
            if let c = inv.confidence, inv.status != .pending { Text("AI confidence \(Int(c * 100))%").font(.caption).foregroundStyle(.secondary) }
            Form {
                TextField("Vendor", text: $vendor)
                TextField("Date (YYYY-MM-DD)", text: $date)
                TextField("Currency (ISO)", text: $currency)
                TextField("Total", text: $total)
                Picker("Category", selection: $category) {
                    ForEach(model.categories) { c in Text("\(c.nameEN) · \(c.nameAR)").tag(c.key) }
                }
            }
            .disabled(inv.status == .confirmed || inv.status == .rejected)
            if !inv.lineItems.isEmpty {
                GroupBox("Line items") {
                    ForEach(Array(inv.lineItems.enumerated()), id: \.offset) { _, li in
                        HStack {
                            Text(li.description).lineLimit(1)
                            Spacer()
                            Text("× \(li.quantity.formatted())").foregroundStyle(.secondary)
                            Text(Money.format(li.totalMinor, currency: inv.currency ?? "USD")).monospacedDigit()
                        }.font(.callout)
                    }
                }
            }
            HStack {
                switch inv.status {
                case .proposed:
                    Button("Confirm") { Task { await model.confirm(inv.id, corrected: corrected(inv)) } }
                        .keyboardShortcut(.defaultAction).disabled(corrected(inv) == nil)
                    Button("Reject", role: .destructive) { Task { await model.reject(inv.id) } }
                case .failed, .pending:
                    Button("Retry AI") { Task { await model.retry(inv.id) } }
                case .confirmed:
                    Label("Counts in your totals", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Reject", role: .destructive) { Task { await model.reject(inv.id) } }
                case .rejected:
                    Text("Rejected. Undo (⌘Z) to restore.").foregroundStyle(.secondary)
                }
            }
            if let text = inv.ocrText, !text.isEmpty {
                DisclosureGroup("Extracted text", isExpanded: $showText) {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The user's edits as an ExtractedInvoice; nil if a required field is invalid.
    func corrected(_ inv: Invoice) -> ExtractedInvoice? {
        guard let day = Day(parsing: date), let cur = Money.normalizeCurrency(currency), let amt = Money.parseAmount(total), amt > 0 else { return nil }
        return ExtractedInvoice(vendor: vendor.isEmpty ? nil : vendor, day: day, currency: cur,
                                totalMinor: Money.toMinor(amt, currency: cur), categoryKey: category,
                                lineItems: inv.lineItems, confidence: inv.confidence ?? 0)
    }
}

struct Preview: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> NSView {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            let v = PDFView(); v.autoScales = true; v.document = PDFDocument(url: url); return v
        }
        let iv = NSImageView(); iv.image = NSImage(contentsOf: url); iv.imageScaling = .scaleProportionallyUpOrDown; return iv
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Analytics

struct AnalyticsView: View {
    @Environment(AppModel.self) var model
    enum Preset: String, CaseIterable, Identifiable {
        case thisMonth = "This month", last30 = "Last 30 days", last12 = "Last 12 months", thisYear = "This year", lastYear = "Last year", all = "All time"
        var id: String { rawValue }
        var range: (Day?, Day?) {
            let t = Day.today
            switch self {
            case .thisMonth: return (t.startOfMonth, t)
            case .last30: return (t.adding(days: -29), t)
            case .last12: return (t.adding(months: -11).startOfMonth, t)
            case .thisYear: return (t.startOfYear, t)
            case .lastYear: let y = t.startOfYear.adding(months: -12); return (y, y.endOfYear)
            case .all: return (nil, nil)
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        let a = model.analytics
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Menu("Range: \(rangeText(a))") {
                            ForEach(Preset.allCases) { p in Button(p.rawValue) { let r = p.range; model.analytics.from = r.0; model.analytics.to = r.1; reload() } }
                        }.fixedSize()
                        Picker("Group by", selection: $model.analytics.groupBy) {
                            ForEach([GroupBy.day, .month, .year, .category, .vendor], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.fixedSize()
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Picker("Chart", selection: $model.analytics.kind) {
                            ForEach(ChartKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.pickerStyle(.segmented).fixedSize()
                        Picker("Category", selection: $model.analytics.category) {
                            Text("All categories").tag(String?.none)
                            ForEach(model.categories) { Text($0.nameEN).tag(String?.some($0.key)) }
                        }.fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                .onChange(of: model.analytics.groupBy) { reload() }
                .onChange(of: model.analytics.category) { reload() }
                let total = model.analyticsRows.reduce(Int64(0)) { $0 + $1.usdMinor }
                Text(Money.format(total)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                SpendChart(rows: model.analyticsRows, kind: a.kind, height: 340)
                Table(model.analyticsRows.filter { $0.count > 0 }.reversed()) {
                    TableColumn("Period / group", value: \.label)
                    TableColumn("Expenses") { Text("\($0.count)").monospacedDigit() }.width(80)
                    TableColumn("Total (USD)") { Text(Money.format($0.usdMinor)).monospacedDigit() }.width(120)
                }
                .frame(minHeight: 220)
            }
            .padding(20)
        }
        .navigationTitle("Analytics")
    }

    func rangeText(_ a: AnalyticsState) -> String {
        guard let f = a.from, let t = a.to else { return "All time" }
        return "\(f.iso) → \(t.iso)"
    }

    func reload() { Task { await model.loadAnalytics() } }
}

// MARK: - Expenses list

struct ExpensesListView: View {
    @Environment(AppModel.self) var model
    @State private var rows: [Expense] = []
    @State private var cursor: PageCursor?
    @State private var selection = Set<Int64>()
    @State private var adding = false
    @State private var confirmDelete = false

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Date") { Text($0.day.iso).monospacedDigit() }.width(95)
            TableColumn("Vendor") { Text($0.vendor ?? "—") }
            TableColumn("Category") { Text(model.categoryName($0.categoryKey)) }
            TableColumn("Amount") { Text(Money.format($0.amountMinor, currency: $0.currency)).monospacedDigit() }.width(120)
            TableColumn("USD") { Text(Money.format($0.usdMinor)).monospacedDigit() }.width(100)
            TableColumn("Source") { e in
                if let i = e.invoiceID { Button("Invoice #\(i)") { model.openCitation(i) }.buttonStyle(.link) } else { Text("Manual").foregroundStyle(.secondary) }
            }.width(100)
        }
        .safeAreaInset(edge: .bottom) {
            if cursor != nil { Button("Load more") { Task { await loadMore() } }.padding(8) }
        }
        .navigationTitle("Expenses")
        .toolbar {
            Button { adding = true } label: { Label("Add", systemImage: "plus") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.disabled(selection.isEmpty)
        }
        .confirmationDialog("Delete \(selection.count) expense(s)? You can undo with ⌘Z.", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { try? await model.store.deleteExpenses(Array(selection)); selection = []; await model.refreshAll() } }
        }
        .sheet(isPresented: $adding) { AddExpenseSheet() }
        .task(id: model.revision) { await reload() }
    }

    func reload() async {
        guard let page = try? await model.store.listExpenses(limit: 100) else { return }
        rows = page.rows; cursor = page.next
    }

    func loadMore() async {
        guard let c = cursor, let page = try? await model.store.listExpenses(limit: 100, after: c) else { return }
        rows += page.rows; cursor = page.next
    }
}

struct AddExpenseSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var date = Day.today.iso
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var category = "other"
    @State private var vendor = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Date (YYYY-MM-DD)", text: $date)
            TextField("Amount", text: $amount)
            TextField("Currency", text: $currency)
            Picker("Category", selection: $category) { ForEach(model.categories) { Text($0.nameEN).tag($0.key) } }
            TextField("Vendor (optional)", text: $vendor)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") { Task { await add() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 380)
    }

    func add() async {
        guard let day = Day(parsing: date) else { error = "Date must be YYYY-MM-DD"; return }
        guard let cur = Money.normalizeCurrency(currency) else { error = "Unknown currency"; return }
        guard let amt = Money.parseAmount(amount), amt > 0 else { error = "Enter a positive amount"; return }
        do {
            try await model.store.addExpense(NewExpense(day: day, amountMinor: Money.toMinor(amt, currency: cur), currency: cur,
                                                        categoryKey: category, vendor: vendor.isEmpty ? nil : vendor))
            await model.refreshAll(); dismiss()
        } catch { self.error = "\(error)" }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) var model
    @State private var rates: [(currency: String, day: Day, rateE6: Int64)] = []
    @State private var cur = ""
    @State private var rate = ""
    @State private var history: [AuditEntry] = []

    var body: some View {
        Form {
            Section("AI (local)") {
                LabeledContent("Ollama", value: model.aiOnline ? "Online" : "Offline")
                LabeledContent("Chat + vision model", value: model.llm.chatModel)
                LabeledContent("Embedding model", value: model.llm.embedModel)
                LabeledContent("Base currency", value: "USD (fixed)")
                LabeledContent("Database", value: "Postgres \(model.store.config.database) @ \(model.store.config.host):\(model.store.config.port) · pgvector")
                Button("Reveal invoice files") { NSWorkspace.shared.activateFileViewerSelecting([ExpenseStore.defaultURL()]) }
            }
            Section("Exchange rates (USD per 1 unit, frozen per expense)") {
                ForEach(Array(rates.enumerated()), id: \.offset) { _, r in
                    LabeledContent("\(r.currency) from \(r.day.iso)", value: String(format: "%.6f", Double(r.rateE6) / 1_000_000))
                }
                HStack {
                    TextField("Currency", text: $cur).frame(width: 90)
                    TextField("USD per unit", text: $rate)
                    Button("Save rate from today") {
                        Task {
                            if let c = Money.normalizeCurrency(cur), let r = Money.parseAmount(rate), r > 0 {
                                try? await model.store.setRate(currency: c, day: .today, usdPerUnit: r)
                                cur = ""; rate = ""; await load()
                            }
                        }
                    }
                }
            }
            Section("Change history (undo with ⌘Z)") {
                ForEach(history) { h in
                    HStack {
                        Text(h.summary).strikethrough(h.undone)
                        Spacer()
                        Text(h.actor == "ai" ? "AI" : h.actor).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task(id: model.revision) { await load() }
    }

    func load() async {
        rates = (try? await model.store.rates()) ?? []
        history = (try? await model.store.auditLog(limit: 30)) ?? []
    }
}
