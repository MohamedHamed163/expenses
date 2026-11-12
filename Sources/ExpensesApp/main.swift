import SwiftUI
import AppKit
import ExpensesKit

struct ExpensesMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Expenses") {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 860)
    }
}

/// Headless commands for testing and the dry run:
///   ExpensesApp --ingest <file>…     import invoices through the full pipeline
///   ExpensesApp --ask "<question>"   ask the assistant (prints tool trace; writes stay pending)
///   ExpensesApp --list               invoices + monthly totals
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        do {
            let store = try await ExpenseStore(config: .fromEnvironment())
            let llm = OllamaLLM()
            switch args.first {
            case "--ingest":
                let ingest = IngestService(store: store, llm: llm, filesDir: ExpenseStore.defaultURL().appendingPathComponent("files"))
                for path in args.dropFirst() {
                    let t = Date()
                    let outcome = await ingest.ingest(URL(fileURLWithPath: path))
                    print("\((path as NSString).lastPathComponent): \(outcome)  [\(String(format: "%.1f", Date().timeIntervalSince(t)))s]")
                }
            case "--ask":
                let search = SearchService(store: store, llm: llm)
                let assistant = Assistant(llm: llm, store: store, search: search, categoryKeys: try await store.categories().map(\.key))
                let turn = try await assistant.ask(args.dropFirst().joined(separator: " "))
                for t in turn.toolTrace { print("tool: \(t)") }
                for e in turn.effects {
                    switch e {
                    case .chart(let c): print("chart: \(c.kind) \(c.title) total=\(Money.format(c.totalUSDMinor)) points=\(c.rows.count)")
                    case .pending(let p): print("PENDING (needs Confirm): \(p.summary)")
                    case .citations(let ids): print("citations: \(ids)")
                    case .navigate(let s): print("navigate: \(s)")
                    default: break
                    }
                }
                if !turn.unverifiedNumbers.isEmpty { print("UNVERIFIED: \(turn.unverifiedNumbers)") }
                print("answer: \(turn.text)")
            case "--transcribe":
                for path in args.dropFirst() {
                    let r = try await VoiceInput.transcribeFile(path)
                    print("\((path as NSString).lastPathComponent) [\(r.language), \(String(format: "%.1f", r.seconds))s]: \(r.text)")
                }
            case "--seed-demo":
                // 14 months of plausible history through the normal audited write path.
                var rng = SystemRandomNumberGenerator()
                let plan: [(String, String, String, ClosedRange<Int>, Int)] = [   // category, vendor, currency, amount range (major), per month
                    ("groceries", "Maadi Fresh Market", "EGP", 400...2200, 5), ("food", "Cafe Riche", "EGP", 150...900, 6),
                    ("transport", "Swvl", "EGP", 40...250, 8), ("utilities", "Cairo Electricity", "EGP", 600...1800, 1),
                    ("software", "Nimbus Cloud Inc.", "USD", 36...41, 1), ("rent", "Zamalek Apartments", "EGP", 15000...15000, 1),
                    ("entertainment", "Galaxy Cinema", "EGP", 200...600, 1), ("health", "صيدليات النور", "EGP", 100...700, 1),
                ]
                let today = Day.today
                var n = 0
                for m in 1...14 {
                    let monthStart = today.startOfMonth.adding(months: -m)
                    for (cat, vendor, cur, range, per) in plan {
                        for _ in 0..<per {
                            let day = monthStart.adding(days: Int.random(in: 0..<Day.daysIn(year: monthStart.year, month: monthStart.month), using: &rng))
                            let amount = Decimal(Int.random(in: range, using: &rng)) + Decimal(Int.random(in: 0...99, using: &rng)) / 100
                            try await store.addExpense(NewExpense(day: day, amountMinor: Money.toMinor(amount, currency: cur), currency: cur,
                                                                  categoryKey: cat, vendor: vendor, note: "demo"), actor: "seed")
                            n += 1
                        }
                    }
                }
                print("seeded \(n) demo expenses over 14 months")
            case "--list":
                for inv in try await store.invoices() {
                    print("#\(inv.id) \(inv.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(inv.vendor ?? "?") \(inv.day?.iso ?? "?") \(inv.totalMinor.map { Money.format($0, currency: inv.currency ?? "USD") } ?? "?") \(inv.reviewReasons)")
                }
                for r in try await store.aggregate(ExpenseFilter(), groupBy: .month, fillGaps: false) { print("\(r.label): \(Money.format(r.usdMinor)) (\(r.count))") }
            default:
                print("usage: ExpensesApp [--ingest files… | --ask question | --list]")
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, first.hasPrefix("--") {
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached { code = await CLI.run(cliArgs); sem.signal() }
    sem.wait()
    exit(code)
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    ExpensesMacApp.main()
}
