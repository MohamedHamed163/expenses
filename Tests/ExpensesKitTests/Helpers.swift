import Foundation
import CoreText
import AppKit
@testable import ExpensesKit

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("expenses_test_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Each test gets its own Postgres schema in the `expenses_test` database.
func makeStore() async throws -> (ExpenseStore, URL) {
    let schema = "t_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    let store = try await ExpenseStore(config: PGConfig(database: "expenses_test", schema: schema))
    return (store, tempDir())
}

func d(_ s: String) -> Day { Day(parsing: s)! }

/// A real text PDF so ingestion runs the true PDFKit path.
func makePDF(_ text: String, at url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ExpensesError.invalid("pdf ctx") }
    ctx.beginPDFPage(nil)
    let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    let setter = CTFramesetterCreateWithAttributedString(attr)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

/// Deterministic model: a closure decides the reply for each call.
final class FakeLLM: LLM, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    let handler: @Sendable (_ messages: [ChatMessage], _ callIndex: Int) throws -> ChatReply
    let embedFails: Bool

    init(embedFails: Bool = false, _ handler: @escaping @Sendable ([ChatMessage], Int) throws -> ChatReply) {
        self.handler = handler; self.embedFails = embedFails
    }

    func chat(_ messages: [ChatMessage], tools: [ToolSpec], temperature: Double) async throws -> ChatReply {
        let idx: Int = lock.withLock { _calls.append(messages); return _calls.count - 1 }
        return try handler(messages, idx)
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if embedFails { throw LLMError.unreachable("embed down") }
        // Bag-of-letters vectors: enough for similarity ordering in tests.
        return texts.map { t in
            var v = [Float](repeating: 0, count: 1024)
            for s in t.lowercased().unicodeScalars { v[Int(s.value % 1024)] += 1 }
            return v
        }
    }
}

func reply(_ text: String) -> ChatReply { ChatReply(content: text, toolCalls: []) }
func callTool(_ name: String, _ args: String) -> ChatReply { ChatReply(content: "", toolCalls: [ToolCall(name: name, argumentsJSON: args)]) }

let goodInvoiceJSON = """
{"vendor":"Carrefour Maadi","invoice_number":"INV-1001","date":"2026-03-14","currency":"EGP","subtotal":"1,200.00","tax":168,
 "total":"1,368.00","category":"groceries","line_items":[{"description":"Rice 5kg","quantity":2,"unit_price":350,"total":700},
 {"description":"Olive oil","quantity":1,"unit_price":500,"total":500}],"confidence":0.95,"language":"en"}
"""
