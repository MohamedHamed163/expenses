import Foundation
import Accelerate

/// Accelerate-backed vector helpers. All embeddings are stored L2-normalized
/// so cosine similarity is a plain dot product.
public enum Vectors {
    public static func l2normalize(_ v: [Float]) -> [Float] {
        var out = v
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrtf(norm)
        if norm > 0 {
            var inverse = 1.0 / norm
            vDSP_vsmul(v, 1, &inverse, &out, 1, vDSP_Length(v.count))
        }
        return out
    }

    /// Dot products of one normalized query against rows of a row-major
    /// matrix (count rows x dim). Row j lives at matrix[j*dim ..< (j+1)*dim].
    /// Bandwidth-bound; one vDSP_dot per row is simple and correct.
    public static func dotProducts(query: [Float], matrix: [Float], count: Int, dim: Int) -> [Float] {
        guard count > 0, dim > 0, query.count == dim, matrix.count == count * dim else { return [] }
        var results = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for row in 0..<count {
                var dot: Float = 0
                vDSP_dotpr(query, 1, base + row * dim, 1, &dot, vDSP_Length(dim))
                results[row] = dot
            }
        }
        return results
    }

    public static func topK(similarities: [Float], k: Int) -> [(index: Int, score: Float)] {
        let indexed = similarities.enumerated().map { (index: $0.offset, score: $0.element) }
        let sorted = indexed.sorted { $0.score > $1.score }
        return Array(sorted.prefix(k))
    }

    public static func floats(from blob: Data, dim: Int) -> [Float] {
        guard blob.count == dim * MemoryLayout<Float>.size else { return [] }
        return blob.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }

    public static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
