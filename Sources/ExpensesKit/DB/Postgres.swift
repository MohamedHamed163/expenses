import Foundation
import PostgresNIO

/// Connection settings. Defaults to the local Homebrew Postgres (trust auth).
public struct PGConfig: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    public var database: String
    /// Postgres schema holding the tables (tests use one schema per test).
    public var schema: String

    public init(host: String = "127.0.0.1", port: Int = 5432, user: String = NSUserName(), password: String? = nil,
                database: String = "expenses", schema: String = "public") {
        self.host = host; self.port = port; self.user = user; self.password = password
        self.database = database; self.schema = schema
    }

    /// EXPENSES_PG_URL=postgres://user:pass@host:port/db overrides the defaults.
    public static func fromEnvironment(database: String = "expenses") -> PGConfig {
        var c = PGConfig(database: database)
        if let raw = ProcessInfo.processInfo.environment["EXPENSES_PG_URL"], let u = URLComponents(string: raw) {
            c.host = u.host ?? c.host
            c.port = u.port ?? c.port
            c.user = u.user ?? c.user
            c.password = u.password
            let db = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !db.isEmpty { c.database = db }
        }
        return c
    }
}

public enum PGValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case bool(Bool)
}

public struct PGRow: Sendable {
    let values: [String: PGValue]
    public func text(_ k: String) -> String? { if case .text(let v)? = values[k] { return v }; return nil }
    public func int(_ k: String) -> Int64? { if case .int(let v)? = values[k] { return v }; return nil }
    public func double(_ k: String) -> Double? {
        switch values[k] { case .double(let v)?: return v; case .int(let v)?: return Double(v); default: return nil }
    }
    public func bool(_ k: String) -> Bool? { if case .bool(let v)? = values[k] { return v }; return nil }
}

/// One leased connection. All statements inside a transaction go through the same `PGConn`.
public struct PGConn: Sendable {
    let conn: PostgresConnection
    let logger: Logger

    /// `?` placeholders are rewritten to `$1, $2…` (no SQL here contains a literal `?`).
    static func numbered(_ sql: String) -> String {
        var out = "", n = 0
        for ch in sql { if ch == "?" { n += 1; out += "$\(n)" } else { out.append(ch) } }
        return out
    }

    @discardableResult
    public func query(_ sql: String, _ params: [PGValue] = []) async throws -> [PGRow] {
        var binds = PostgresBindings()
        for p in params {
            switch p {
            case .null: binds.appendNull()
            case .int(let v): try binds.append(v)
            case .double(let v): try binds.append(v)
            case .text(let v): try binds.append(v)
            case .bool(let v): try binds.append(v)
            }
        }
        let rows = try await conn.query(PostgresQuery(unsafeSQL: Self.numbered(sql), binds: binds), logger: logger)
        var out: [PGRow] = []
        for try await row in rows {
            var dict: [String: PGValue] = [:]
            for cell in row { dict[cell.columnName] = Self.decode(cell) }
            out.append(PGRow(values: dict))
        }
        return out
    }

    public func run(_ sql: String, _ params: [PGValue] = []) async throws { try await query(sql, params) }

    public func scalar(_ sql: String, _ params: [PGValue] = []) async throws -> Int64? {
        guard let r = try await query(sql, params).first, let v = r.values.values.first else { return nil }
        if case .int(let i) = v { return i }
        return nil
    }

    public func scalarText(_ sql: String, _ params: [PGValue] = []) async throws -> String? {
        guard let r = try await query(sql, params).first, case .text(let s)? = r.values.values.first else { return nil }
        return s
    }

    static func decode(_ cell: PostgresCell) -> PGValue {
        guard cell.bytes != nil else { return .null }
        switch cell.dataType {
        case .int2: return (try? cell.decode(Int16.self)).map { .int(Int64($0)) } ?? .null
        case .int4: return (try? cell.decode(Int32.self)).map { .int(Int64($0)) } ?? .null
        case .int8: return (try? cell.decode(Int64.self)).map { .int($0) } ?? .null
        case .float4: return (try? cell.decode(Float.self)).map { .double(Double($0)) } ?? .null
        case .float8: return (try? cell.decode(Double.self)).map { .double($0) } ?? .null
        case .bool: return (try? cell.decode(Bool.self)).map { .bool($0) } ?? .null
        default: return (try? cell.decode(String.self)).map { .text($0) } ?? .null
        }
    }
}

/// Owns the connection pool. `read` leases a connection; `transaction` runs
/// BEGIN … COMMIT on one leased connection and ROLLBACKs on any error.
public final class PGDatabase: Sendable {
    let client: PostgresClient
    let logger: Logger
    let runTask: Task<Void, Never>
    public let config: PGConfig

    public init(_ config: PGConfig) {
        self.config = config
        var cfg = PostgresClient.Configuration(host: config.host, port: config.port, username: config.user,
                                               password: config.password, database: config.database, tls: .disable)
        cfg.options.additionalStartupParameters = [("search_path", "\(config.schema), public")]
        cfg.options.maximumConnections = 8
        var log = Logger(label: "expenses.pg")
        log.logLevel = .error
        logger = log
        let client = PostgresClient(configuration: cfg, backgroundLogger: log)
        self.client = client
        runTask = Task { await client.run() }
    }

    deinit { runTask.cancel() }

    public func read<T>(_ body: (PGConn) async throws -> T) async throws -> T {
        try await client.withConnection { try await body(PGConn(conn: $0, logger: logger)) }
    }

    public func transaction<T>(_ body: (PGConn) async throws -> T) async throws -> T {
        try await client.withConnection { raw in
            let c = PGConn(conn: raw, logger: logger)
            try await c.run("BEGIN")
            do {
                let v = try await body(c)
                try await c.run("COMMIT")
                return v
            } catch {
                try? await c.run("ROLLBACK")
                throw error
            }
        }
    }

    public static func isUniqueViolation(_ error: Error) -> Bool {
        (error as? PSQLError)?.serverInfo?[.sqlState] == PostgresError.Code.uniqueViolation.raw
    }
}
