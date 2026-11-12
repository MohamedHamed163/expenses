import Foundation

/// Hybrid retrieval: Postgres full-text (GIN/tsvector) + pgvector HNSW cosine
/// search, merged with Reciprocal Rank Fusion (k = 60). Results are grouped per
/// invoice so the assistant can cite invoice ids.
public struct SearchService: Sendable {
    let store: ExpenseStore
    let llm: LLM?

    public init(store: ExpenseStore, llm: LLM?) { self.store = store; self.llm = llm }

    public struct Hit: Sendable, Hashable {
        public let invoiceID: Int64
        public let snippet: String
        public let score: Double
    }

    public func search(_ query: String, limit: Int = 5) async throws -> [Hit] {
        var lists = [try await store.ftsSearch(query, limit: 30)]
        // Embedding failure degrades to keyword-only search instead of failing.
        if let llm, let q = try? await llm.embed([query]).first {
            lists.append(try await store.vectorSearch(q, limit: 30))
        }
        return Self.fuse(lists, limit: limit)
    }

    static func fuse(_ lists: [[ExpenseStore.ChunkHit]], limit: Int, k: Double = 60) -> [Hit] {
        var score: [Int64: Double] = [:]
        var chunk: [Int64: ExpenseStore.ChunkHit] = [:]
        for list in lists {
            for h in list {
                score[h.chunkID, default: 0] += 1 / (k + Double(h.rank))
                chunk[h.chunkID] = h
            }
        }
        var best: [Int64: Hit] = [:]   // best chunk per invoice
        for (id, s) in score {
            guard let h = chunk[id] else { continue }
            if (best[h.invoiceID]?.score ?? -1) < s {
                best[h.invoiceID] = Hit(invoiceID: h.invoiceID, snippet: String(h.text.prefix(300)), score: s)
            }
        }
        return Array(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.invoiceID < $1.invoiceID }.prefix(limit))
    }
}
