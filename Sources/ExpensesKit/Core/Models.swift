import Foundation

public enum InvoiceStatus: String, Sendable, Codable, CaseIterable {
    case pending     // saved, waiting for AI extraction (or retrying)
    case proposed    // extracted, needs human review; excluded from totals
    case confirmed   // counts in totals (has an expense row)
    case rejected    // user rejected
    case failed      // extraction failed 3 times; user can retry
}

public struct Category: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let key: String
    public let nameEN: String
    public let nameAR: String
}

public struct LineItem: Sendable, Codable, Hashable {
    public var description: String
    public var quantity: Double
    public var unitMinor: Int64?
    public var totalMinor: Int64
    public init(description: String, quantity: Double, unitMinor: Int64?, totalMinor: Int64) {
        self.description = description; self.quantity = quantity
        self.unitMinor = unitMinor; self.totalMinor = totalMinor
    }
}

/// What the model extracted, after deterministic parsing/normalization.
public struct ExtractedInvoice: Sendable, Codable, Hashable {
    public var vendor: String?
    public var invoiceNumber: String?
    public var day: Day?
    public var currency: String?
    public var subtotalMinor: Int64?
    public var taxMinor: Int64?
    public var totalMinor: Int64?
    public var categoryKey: String?
    public var lineItems: [LineItem]
    public var confidence: Double
    public var language: String?

    public init(vendor: String? = nil, invoiceNumber: String? = nil, day: Day? = nil, currency: String? = nil,
                subtotalMinor: Int64? = nil, taxMinor: Int64? = nil, totalMinor: Int64? = nil,
                categoryKey: String? = nil, lineItems: [LineItem] = [], confidence: Double = 0, language: String? = nil) {
        self.vendor = vendor; self.invoiceNumber = invoiceNumber; self.day = day; self.currency = currency
        self.subtotalMinor = subtotalMinor; self.taxMinor = taxMinor; self.totalMinor = totalMinor
        self.categoryKey = categoryKey; self.lineItems = lineItems; self.confidence = confidence; self.language = language
    }
}

public struct Invoice: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var status: InvoiceStatus
    public var filePath: String
    public var originalName: String
    public var vendor: String?
    public var day: Day?
    public var currency: String?
    public var totalMinor: Int64?
    public var categoryKey: String?
    public var confidence: Double?
    public var reviewReasons: [String]
    public var duplicateOf: Int64?
    public var attempts: Int
    public var lastError: String?
    public var ocrText: String?
    public var lineItems: [LineItem]
}

public struct Expense: Sendable, Identifiable, Hashable, Codable {
    public let id: Int64
    public var invoiceID: Int64?
    public var day: Day
    public var categoryKey: String
    public var vendor: String?
    public var amountMinor: Int64
    public var currency: String
    public var fxRateE6: Int64
    public var usdMinor: Int64
    public var note: String?
}

public enum GroupBy: String, Sendable, Codable, CaseIterable {
    case none, day, month, year, category, vendor
}

/// One row of an aggregate: label is human-readable, key sorts.
public struct AggregateRow: Sendable, Hashable, Codable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let usdMinor: Int64
    public let count: Int
}

public struct ExpenseFilter: Sendable, Hashable {
    public var from: Day?
    public var to: Day?
    public var categoryKey: String?
    public var vendor: String?
    public init(from: Day? = nil, to: Day? = nil, categoryKey: String? = nil, vendor: String? = nil) {
        self.from = from; self.to = to; self.categoryKey = categoryKey; self.vendor = vendor
    }
}

/// Keyset cursor for lists: (day DESC, id DESC). Stable under inserts, O(log n) per page.
public struct PageCursor: Sendable, Hashable {
    public let day: Int
    public let id: Int64
}

/// A new expense typed by the user or proposed by the AI.
public struct NewExpense: Sendable, Hashable, Codable {
    public var day: Day
    public var amountMinor: Int64
    public var currency: String
    public var categoryKey: String
    public var vendor: String?
    public var note: String?
    public init(day: Day, amountMinor: Int64, currency: String, categoryKey: String, vendor: String? = nil, note: String? = nil) {
        self.day = day; self.amountMinor = amountMinor; self.currency = currency
        self.categoryKey = categoryKey; self.vendor = vendor; self.note = note
    }
}

public struct ExpenseEdit: Sendable, Hashable, Codable {
    public var day: Day?
    public var amountMinor: Int64?
    public var currency: String?
    public var categoryKey: String?
    public var vendor: String?
    public var note: String?
    public init(day: Day? = nil, amountMinor: Int64? = nil, currency: String? = nil, categoryKey: String? = nil, vendor: String? = nil, note: String? = nil) {
        self.day = day; self.amountMinor = amountMinor; self.currency = currency
        self.categoryKey = categoryKey; self.vendor = vendor; self.note = note
    }
}

public struct AuditEntry: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let action: String
    public let actor: String
    public let summary: String
    public let undone: Bool
    public let createdAt: Date
}

public enum ExpensesError: Error, CustomStringConvertible, Equatable {
    case duplicateFile(existingInvoiceID: Int64)
    case notFound(String)
    case invalid(String)
    case noRate(currency: String)
    case nothingToUndo

    public var description: String {
        switch self {
        case .duplicateFile(let id): return "This file was already imported (invoice #\(id))."
        case .notFound(let m): return "Not found: \(m)"
        case .invalid(let m): return "Invalid: \(m)"
        case .noRate(let c): return "No exchange rate for \(c). Add one in Settings."
        case .nothingToUndo: return "Nothing to undo."
        }
    }
}
