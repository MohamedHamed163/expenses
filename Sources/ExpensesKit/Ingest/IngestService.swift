import Foundation
import CryptoKit

/// Upload -> save pending (always) -> extract with retries -> validate -> commit
/// in one transaction -> index for RAG. Each invoice is independent: one failure
/// never rolls back another.
public actor IngestService {
    let store: ExpenseStore
    let llm: LLM
    let filesDir: URL
    public let maxAttempts: Int
    /// Backoff between attempts; injectable so tests don't sleep.
    let backoff: @Sendable (Int) async -> Void
    let today: @Sendable () -> Day

    public init(store: ExpenseStore, llm: LLM, filesDir: URL, maxAttempts: Int = 3,
                backoff: @escaping @Sendable (Int) async -> Void = { attempt in
                    try? await Task.sleep(nanoseconds: UInt64(pow(4.0, Double(attempt - 1))) * 1_000_000_000)
                },
                today: @escaping @Sendable () -> Day = { .today }) {
        self.store = store; self.llm = llm; self.filesDir = filesDir
        self.maxAttempts = maxAttempts; self.backoff = backoff; self.today = today
    }

    public enum Outcome: Sendable, Equatable {
        case confirmed(invoiceID: Int64)
        case needsReview(invoiceID: Int64, reasons: [String])
        case duplicateFile(existingInvoiceID: Int64)
        case failed(invoiceID: Int64, error: String)
    }

    /// Copies the file into app storage and records it, before any AI call.
    public func importFile(_ url: URL) async throws -> Int64 {
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let dest = filesDir.appendingPathComponent("\(sha).\(url.pathExtension.lowercased())")
        if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest) }
        return try await store.insertPendingInvoice(sha256: sha, filePath: dest.path, originalName: url.lastPathComponent)
    }

    /// Import + process. Never throws for AI failures: they become `.failed` and stay retryable.
    public func ingest(_ url: URL) async -> Outcome {
        let id: Int64
        do { id = try await importFile(url) }
        catch ExpensesError.duplicateFile(let existing) { return .duplicateFile(existingInvoiceID: existing) }
        catch { return .failed(invoiceID: -1, error: "\(error)") }
        return await process(invoiceID: id)
    }

    public func process(invoiceID: Int64) async -> Outcome {
        let invoice: Invoice
        do { invoice = try await store.invoice(invoiceID) } catch { return .failed(invoiceID: invoiceID, error: "\(error)") }
        // Text extraction is deterministic; a failure here is not retried.
        let text: TextExtractor.Result
        do { text = try TextExtractor.extract(from: URL(fileURLWithPath: invoice.filePath)) }
        catch {
            _ = try? await store.recordAttemptFailure(invoiceID: invoiceID, error: "\(error)", maxAttempts: 1)
            return .failed(invoiceID: invoiceID, error: "\(error)")
        }
        let keys = ((try? await store.categories()) ?? []).map(\.key)
        let extractor = InvoiceExtractor(llm: llm, categoryKeys: keys)
        var attempt = invoice.attempts
        while true {
            attempt += 1
            do {
                let out = try await extractor.extract(text: text.text, imageBase64: text.usedOCR ? text.pageImageBase64 : nil)
                return try await commit(invoiceID: invoiceID, out, ocrText: text.text)
            } catch {
                let n = (try? await store.recordAttemptFailure(invoiceID: invoiceID, error: "\(error)", maxAttempts: maxAttempts)) ?? attempt
                if n >= maxAttempts { return .failed(invoiceID: invoiceID, error: "\(error)") }
                await backoff(n)
            }
        }
    }

    private func commit(invoiceID: Int64, _ out: InvoiceExtractor.Output, ocrText: String) async throws -> Outcome {
        let e = out.invoice
        var hasRate = false
        if let c = e.currency { hasRate = (try? await store.rateE6(currency: c, on: e.day ?? today())) != nil }
        let dup = try await store.likelyDuplicate(of: invoiceID, vendor: e.vendor, day: e.day, totalMinor: e.totalMinor, currency: e.currency)
        let decision = Validator.decide(e, today: today(), hasRate: hasRate, duplicateOf: dup)
        try await store.applyExtraction(invoiceID: invoiceID, extracted: e, ocrText: ocrText, rawJSON: out.rawJSON,
                                        reasons: decision.reasons, duplicateOf: dup, autoConfirm: decision.autoConfirm)
        await index(invoiceID: invoiceID, e, ocrText: ocrText)
        return decision.autoConfirm ? .confirmed(invoiceID: invoiceID) : .needsReview(invoiceID: invoiceID, reasons: decision.reasons)
    }

    /// RAG indexing. Embedding failure is not fatal: keyword search still works.
    func index(invoiceID: Int64, _ e: ExtractedInvoice, ocrText: String) async {
        var summary = "Invoice #\(invoiceID)"
        if let v = e.vendor { summary += " from \(v)" }
        if let d = e.day { summary += " on \(d.iso)" }
        if let t = e.totalMinor, let c = e.currency { summary += ", total \(Money.format(t, currency: c))" }
        if let k = e.categoryKey { summary += ", category \(k)" }
        if !e.lineItems.isEmpty { summary += ". Items: " + e.lineItems.map(\.description).joined(separator: "; ") }
        let texts = [summary] + Self.chunk(ocrText, size: 700, overlap: 100)
        let vectors = try? await llm.embed(texts)
        let rows = texts.enumerated().map { (i, t) in (text: t, embedding: vectors.flatMap { i < $0.count ? $0[i] : nil }) }
        try? await store.replaceChunks(invoiceID: invoiceID, chunks: rows)
    }

    static func chunk(_ text: String, size: Int, overlap: Int) -> [String] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var out: [String] = []
        var start = 0
        while start < chars.count {
            let end = min(start + size, chars.count)
            out.append(String(chars[start..<end]))
            if end == chars.count { break }
            start = end - overlap
        }
        return out
    }

    /// On launch: retry anything left pending (e.g. AI was offline last time).
    public func processPending() async -> [Outcome] {
        var results: [Outcome] = []
        for id in (try? await store.pendingInvoiceIDs()) ?? [] { results.append(await process(invoiceID: id)) }
        return results
    }

    public func retry(invoiceID: Int64) async -> Outcome {
        try? await store.resetForRetry(invoiceID: invoiceID)
        return await process(invoiceID: invoiceID)
    }
}
