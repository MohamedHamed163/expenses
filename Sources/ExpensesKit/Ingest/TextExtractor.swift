import Foundation
import PDFKit
import Vision
import AppKit

/// Turns an invoice file into text. Text PDFs use their embedded text;
/// scanned PDFs and photos are OCR'd on-device with Apple Vision (Arabic + English).
public enum TextExtractor {
    public struct Result: Sendable {
        public var text: String
        public var usedOCR: Bool
        /// First page as PNG base64, sent to the vision model when OCR was needed.
        public var pageImageBase64: String?
    }

    public static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"]

    public static func extract(from url: URL) throws -> Result {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ExpensesError.invalid("unsupported file type .\(ext)") }
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ExpensesError.invalid("cannot open PDF") }
            let embedded = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstPage = doc.page(at: 0).flatMap(render(page:))
            if embedded.count >= 40 {
                return Result(text: embedded, usedOCR: false, pageImageBase64: nil)
            }
            var pages: [String] = []
            for i in 0..<min(doc.pageCount, 5) {
                if let img = doc.page(at: i).flatMap(render(page:)) { pages.append(try ocr(img)) }
            }
            return Result(text: pages.joined(separator: "\n\n"), usedOCR: true, pageImageBase64: firstPage.flatMap(pngBase64))
        }
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExpensesError.invalid("cannot read image")
        }
        return Result(text: try ocr(image), usedOCR: true, pageImageBase64: pngBase64(downscale(image, maxSide: 1600)))
    }

    public static func ocr(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ar-SA", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).sorted {
            // Top-to-bottom reading order (Vision's origin is bottom-left).
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func downscale(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let s = CGFloat(maxSide) / CGFloat(longest)
        let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func pngBase64(_ image: CGImage) -> String? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
