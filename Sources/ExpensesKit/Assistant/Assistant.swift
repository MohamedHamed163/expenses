import Foundation

/// The "Ask AI" agent: a bounded tool-calling loop. The model chooses tools and
/// writes prose; every number comes from a tool result, and numbers in the final
/// answer that no tool produced are flagged.
public actor Assistant {
    let llm: LLM
    let executor: ToolExecutor
    let tools: [ToolSpec]
    let today: Day
    public let maxRounds: Int
    private var history: [ChatMessage] = []
    /// Optional local JSONL log of every turn (question, tool calls, tool results, answer) for diagnosis.
    private var logURL: URL?
    public func setLogURL(_ url: URL?) { logURL = url }

    private func log(_ question: String, trace: [String], outputs: [String], answer: String, unverified: [String]) {
        guard let logURL else { return }
        let entry: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "question": question, "tools": trace,
                                    "tool_results": outputs.map { String($0.prefix(2000)) }, "answer": answer, "unverified": unverified]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: logURL) }
    }

    public init(llm: LLM, store: ExpenseStore, search: SearchService, categoryKeys: [String], today: Day = .today, maxRounds: Int = 6) {
        self.llm = llm
        self.executor = ToolExecutor(store: store, search: search, today: today)
        self.tools = ToolCatalog.all(categoryKeys: categoryKeys)
        self.today = today
        self.maxRounds = maxRounds
    }

    public struct Turn: Sendable {
        public var text: String
        public var effects: [ToolExecutor.Effect]
        public var toolTrace: [String]
        public var unverifiedNumbers: [String]
        public var pending: [PendingAction] {
            effects.compactMap { if case .pending(let p) = $0 { return p } else { return nil } }
        }
    }

    func systemPrompt() -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE"; f.locale = Locale(identifier: "en_US"); f.timeZone = TimeZone(identifier: "UTC")
        let lastMonth = today.startOfMonth.adding(months: -1)
        let ym: (Day) -> String = { String($0.iso.prefix(7)) }
        return """
        You are the assistant inside "Expenses", a private macOS expense tracker. Today is \(today.iso) (\(f.string(from: today.date))).
        Date anchors (use these exactly): today = \(today.iso); yesterday = \(today.adding(days: -1).iso); this month = \(ym(today)); last month = \(ym(lastMonth)); this year = \(today.year); last year = \(today.year - 1).
        A month named without a year means its most recent occurrence that is not in the future (e.g. "September" = \(Self.mostRecent(month: 9, today: today))).
        All totals are in USD; foreign invoices were converted at a rate frozen when they were confirmed.
        Rules:
        1. For ANY amount, total, count or comparison, call query_expenses (or show_chart). Never calculate, estimate or remember numbers yourself; quote figures exactly as the tool returns them.
        2. Resolve relative dates with the anchors above and pass explicit periods or from/to dates.
        3. To see/plot/graph, call show_chart; the chart appears in the app. To change data, call the write tool; the app shows a Confirm card, so say it is waiting for confirmation, never that it is done.
        4. For questions about what was bought or which invoice, call search_invoices and cite invoices as [#id]. If nothing is found, say so; do not guess.
        5. If a request is ambiguous (e.g. which expense to delete), list candidates with list_expenses and ask.
        6. Never convert currencies yourself; use usd_total_counted or query_expenses. If a tool returns an error (e.g. no vendor matches), fix the arguments and call it again; an error is not "no spending".
        7. For an invoice's items, quantities or prices, call get_invoice. Only state invoice fields that a tool returned; if a field is unknown (e.g. no date on the receipt), say it is missing. Never fill it in from what the user said.
        8. To compare two periods, call compare_periods (it computes the difference); never subtract numbers yourself.
        9. Reply briefly, in the language the [reply in …] tag on the user's message names.
        """
    }

    public func reset() { history = [] }

    static func mostRecent(month: Int, today: Day) -> String {
        let year = month <= today.month ? today.year : today.year - 1
        return String(format: "%04d-%02d", year, month)
    }

    /// Language is decided by code from the script the user typed, not guessed by the model.
    static func replyLanguage(_ text: String) -> String {
        let arabic = text.unicodeScalars.filter { (0x0600...0x06FF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        return arabic > latin ? "Arabic" : "English"
    }

    public func ask(_ userText: String) async throws -> Turn {
        if history.isEmpty { history.append(.system(systemPrompt())) }
        let language = Self.replyLanguage(userText)
        history.append(.user("\(userText)\n[reply in \(language)]"))
        var effects: [ToolExecutor.Effect] = []
        var trace: [String] = []
        var toolOutputs: [String] = []
        for _ in 0..<maxRounds {
            let reply = try await llm.chat(history, tools: tools, temperature: 0)
            if reply.toolCalls.isEmpty {
                history.append(ChatMessage(role: "assistant", content: reply.content))
                trimHistory()
                var text = reply.content
                let pending = effects.compactMap { e -> PendingAction? in if case .pending(let p) = e { return p }; return nil }
                if !pending.isEmpty {
                    // The model must not claim a write happened; code writes this message.
                    text = (language == "Arabic" ? "في انتظار تأكيدك: " : "Waiting for your confirmation: ")
                        + pending.map(\.summary).joined(separator: "; ")
                }
                let unverified = Self.unverifiedAmounts(in: text, sources: toolOutputs)
                log(userText, trace: trace, outputs: toolOutputs, answer: text, unverified: unverified)
                return Turn(text: text, effects: Self.filterCitations(effects, text: text), toolTrace: trace, unverifiedNumbers: unverified)
            }
            history.append(ChatMessage(role: "assistant", content: reply.content, toolCalls: reply.toolCalls))
            for call in reply.toolCalls {
                let result = await executor.run(call)
                trace.append("\(call.name)(\(call.argumentsJSON))")
                toolOutputs.append(result.forModel)
                effects.append(contentsOf: result.effects)
                history.append(ChatMessage(role: "tool", content: result.forModel, toolName: call.name))
            }
        }
        trimHistory()
        return Turn(text: "I couldn't finish that within \(maxRounds) steps. Try a more specific request.",
                    effects: effects, toolTrace: trace, unverifiedNumbers: [])
    }

    public func commit(_ p: PendingAction) async throws -> String {
        let msg = try await executor.commit(p)
        history.append(.user("[app] The user confirmed: \(p.summary). Result: \(msg)"))
        return msg
    }

    /// Something changed outside the chat (confirm/reject/edit/import in the UI). Tell the
    /// model so it doesn't answer from stale tool results earlier in the conversation.
    public func noteAppEvent(_ text: String) {
        guard !history.isEmpty else { return }
        history.append(.user("[app event] \(text) Any earlier tool results about this are now out of date; call the tools again."))
    }

    public func decline(_ p: PendingAction) {
        history.append(.user("[app] The user cancelled: \(p.summary)."))
    }

    /// Keep the system prompt + the last 30 messages, never splitting a tool exchange.
    private func trimHistory() {
        guard history.count > 31 else { return }
        var tail = Array(history.suffix(30))
        while let first = tail.first, first.role == "tool" || first.role == "assistant" { tail.removeFirst() }
        history = [history[0]] + tail
    }

    /// Keep only invoices the answer mentions (#id); if it names none, keep the top hit.
    static func filterCitations(_ effects: [ToolExecutor.Effect], text: String) -> [ToolExecutor.Effect] {
        let mentioned = Set(numbersAfterHash(Money.westernizeDigits(text)))
        return effects.map { e in
            guard case .citations(let ids) = e else { return e }
            let kept = ids.filter { mentioned.contains($0) }
            return .citations(kept.isEmpty ? Array(ids.prefix(1)) : kept)
        }
    }

    static func numbersAfterHash(_ s: String) -> [Int64] {
        guard let re = try? NSRegularExpression(pattern: #"#\s?(\d+)"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).flatMap { Int64(s[$0]) }
        }
    }

    /// Money amounts in the answer ("$1,234.56", "1234.56 USD") that do not appear in any tool output.
    static func unverifiedAmounts(in text: String, sources: [String]) -> [String] {
        let western = Money.westernizeDigits(text)
        let pattern = #"\$\s?\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:USD|dollars?|دولار)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let found = re.matches(in: western, range: NSRange(western.startIndex..., in: western)).compactMap { Range($0.range, in: western).map { String(western[$0]) } }
        let sourceNumbers = Set(sources.flatMap { numbers(in: $0) })
        return found.filter { amount in
            let nums = numbers(in: amount)
            return !nums.isEmpty && !nums.allSatisfy { sourceNumbers.contains($0) }
        }
    }

    static func numbers(in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d[\d,]*(?:\.\d+)?"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { canonical(String(s[$0])) }
        }
    }

    /// "1,234.50" and "1234.5" compare equal.
    static func canonical(_ n: String) -> String {
        let d = Decimal(string: n.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return NSDecimalNumber(decimal: d).stringValue
    }
}
