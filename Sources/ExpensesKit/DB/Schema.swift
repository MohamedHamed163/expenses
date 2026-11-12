import Foundation

/// Versioned migrations, tracked in `schema_version`. Postgres 17 + pgvector.
enum Schema {
    /// qwen3-embedding:0.6b produces 1024-dimensional vectors.
    static let embeddingDim = 1024

    static let v1: [String] = [
        """
        CREATE TABLE categories(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            name_en TEXT NOT NULL,
            name_ar TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE vendors(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name TEXT NOT NULL,
            norm_name TEXT NOT NULL UNIQUE
        )
        """,
        """
        CREATE TABLE invoices(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            file_sha256 TEXT NOT NULL UNIQUE,
            file_path TEXT NOT NULL,
            original_name TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending','proposed','confirmed','rejected','failed')),
            vendor_id BIGINT REFERENCES vendors(id),
            invoice_number TEXT,
            issue_day BIGINT,
            currency TEXT,
            subtotal_minor BIGINT,
            tax_minor BIGINT,
            total_minor BIGINT,
            category_key TEXT,
            confidence DOUBLE PRECISION,
            ocr_text TEXT,
            extraction_json JSONB,
            review_reasons JSONB NOT NULL DEFAULT '[]',
            duplicate_of BIGINT REFERENCES invoices(id),
            attempts BIGINT NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """,
        "CREATE INDEX invoices_status ON invoices(status, id DESC)",
        "CREATE INDEX invoices_dup ON invoices(vendor_id, issue_day, total_minor)",
        """
        CREATE TABLE line_items(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
            description TEXT NOT NULL,
            quantity DOUBLE PRECISION NOT NULL DEFAULT 1,
            unit_minor BIGINT,
            total_minor BIGINT NOT NULL
        )
        """,
        "CREATE INDEX line_items_invoice ON line_items(invoice_id)",
        """
        CREATE TABLE expenses(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            invoice_id BIGINT REFERENCES invoices(id) ON DELETE SET NULL,
            day BIGINT NOT NULL CHECK (day BETWEEN 19000101 AND 22001231),
            category_id BIGINT NOT NULL REFERENCES categories(id),
            vendor_id BIGINT REFERENCES vendors(id),
            amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
            currency TEXT NOT NULL,
            fx_rate_e6 BIGINT NOT NULL,
            usd_minor BIGINT NOT NULL,
            note TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            deleted_at TIMESTAMPTZ
        )
        """,
        // Covering partial indexes: chart queries become index-only range scans.
        "CREATE INDEX expenses_day ON expenses(day) INCLUDE (usd_minor) WHERE deleted_at IS NULL",
        "CREATE INDEX expenses_cat_day ON expenses(category_id, day) INCLUDE (usd_minor) WHERE deleted_at IS NULL",
        "CREATE INDEX expenses_vendor_day ON expenses(vendor_id, day) INCLUDE (usd_minor) WHERE deleted_at IS NULL",
        "CREATE INDEX expenses_list ON expenses(day DESC, id DESC) WHERE deleted_at IS NULL",
        "CREATE INDEX expenses_invoice ON expenses(invoice_id)",
        """
        CREATE TABLE fx_rates(
            currency TEXT NOT NULL,
            day BIGINT NOT NULL,
            rate_e6 BIGINT NOT NULL CHECK (rate_e6 > 0),
            PRIMARY KEY(currency, day)
        )
        """,
        // RAG: pgvector embedding + Postgres full-text in the same row and transaction.
        // 'simple' config: no stemming, works for Arabic and English tokens alike.
        """
        CREATE TABLE chunks(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            embedding vector(\(embeddingDim)),
            tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', text)) STORED
        )
        """,
        "CREATE INDEX chunks_invoice ON chunks(invoice_id)",
        "CREATE INDEX chunks_tsv ON chunks USING gin(tsv)",
        "CREATE INDEX chunks_embedding ON chunks USING hnsw (embedding vector_cosine_ops)",
        """
        CREATE TABLE audit_log(
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            action TEXT NOT NULL,
            actor TEXT NOT NULL,
            summary TEXT NOT NULL,
            undo_json JSONB NOT NULL,
            undone BOOLEAN NOT NULL DEFAULT false
        )
        """,
        "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ]

    static let migrations: [[String]] = [v1]

    static let categories: [(String, String, String)] = [
        ("food", "Food & dining", "طعام ومطاعم"),
        ("groceries", "Groceries", "بقالة"),
        ("transport", "Transport", "مواصلات"),
        ("travel", "Travel", "سفر"),
        ("utilities", "Utilities", "فواتير ومرافق"),
        ("rent", "Rent", "إيجار"),
        ("software", "Software & subscriptions", "برمجيات واشتراكات"),
        ("electronics", "Electronics", "إلكترونيات"),
        ("health", "Health", "صحة"),
        ("entertainment", "Entertainment", "ترفيه"),
        ("office", "Office supplies", "مستلزمات مكتبية"),
        ("other", "Other", "أخرى"),
    ]

    /// Default rates (USD per 1 unit), editable in Settings. Dated 2020-01-01 so
    /// they apply to any invoice until the user adds a newer rate.
    static let defaultRates: [(String, String)] = [
        ("EGP", "0.0205"), ("SAR", "0.2667"), ("AED", "0.2723"), ("EUR", "1.08"), ("GBP", "1.27"),
        ("KWD", "3.25"), ("QAR", "0.2747"), ("BHD", "2.6596"), ("OMR", "2.5974"), ("JOD", "1.4104"),
        ("JPY", "0.0067"),
    ]

    /// Runs pending migrations in one transaction, guarded by an advisory lock
    /// so two app instances starting together can't migrate twice.
    static func migrate(_ db: PGDatabase) async throws {
        let schema = db.config.schema
        try await db.read { c in
            try await c.run("CREATE EXTENSION IF NOT EXISTS vector")
            if schema != "public" { try await c.run("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"") }
        }
        try await db.transaction { c in
            try await c.run("SELECT pg_advisory_xact_lock(hashtext(?))", [.text("expenses-migrate-\(schema)")])
            try await c.run("CREATE TABLE IF NOT EXISTS schema_version(version BIGINT NOT NULL)")
            let current = Int(try await c.scalar("SELECT max(version) FROM schema_version") ?? 0)
            guard current < migrations.count else { return }
            for v in current..<migrations.count {
                for stmt in migrations[v] { try await c.run(stmt) }
            }
            if current == 0 {
                for (k, en, ar) in categories {
                    try await c.run("INSERT INTO categories(key, name_en, name_ar) VALUES (?,?,?)", [.text(k), .text(en), .text(ar)])
                }
                for (cur, r) in defaultRates {
                    let e6 = Money.rateE6(fromUSDPerUnit: Decimal(string: r)!)
                    try await c.run("INSERT INTO fx_rates(currency, day, rate_e6) VALUES (?,?,?)", [.text(cur), .int(20200101), .int(e6)])
                }
            }
            try await c.run("INSERT INTO schema_version(version) VALUES (?)", [.int(Int64(migrations.count))])
        }
    }
}
