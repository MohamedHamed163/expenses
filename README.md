# Expenses

**A private macOS expense tracker.** Drop in invoices (PDF, scan or phone photo, Arabic or English), let a **local** AI read them, see charts by day, month or year, and control the whole app by **chatting or speaking** to it. Nothing leaves your Mac.

![Dashboard](docs/screenshots/dashboard.png)

📄 **Build report (PDF):** [docs/Expenses-Build-Report.pdf](docs/Expenses-Build-Report.pdf) covers what was built, how it works, the test and benchmark results, and the frameworks used.

## Features

| | |
|---|---|
| 📥 **Invoice import** | Drag and drop PDFs or photos. PDFKit reads text PDFs; Apple Vision OCRs scans and photos (Arabic + English); `qwen3.5:9b` extracts vendor, date, currency, totals and line items as strict JSON |
| ✅ **Trust rules** | Auto-confirmed only if confidence ≥ 0.9, line items explain the total (±1%), the date is plausible, the currency and rate are known, and it isn't a likely duplicate. Otherwise it goes to **Needs review** with readable reasons |
| 💱 **Multi-currency** | Amounts stored as integer minor units (KWD has 3 decimals, JPY 0); converted to **USD** with a rate **frozen per expense** |
| 🔎 **RAG over invoices** | Postgres **pgvector** (HNSW, cosine) + full-text `tsvector`, merged with Reciprocal Rank Fusion; answers cite invoices `[#id]` |
| 💬 **Ask AI with full control** | 14 tools: query totals, charts, compare periods, search, open, navigate, add, edit, split, delete, confirm, exchange rates, undo |
| 🎙️ **Voice** | Push-to-talk with on-device Apple Speech (Arabic / English) |
| 📊 **Charts** | Swift Charts, by day, month, year, category or vendor; bar, line or donut |
| ↩️ **Undo everything** | Every write is one transaction plus an audit row with its inverse operation; AI writes need a **Confirm** click |

### Hallucination control: the model reads and talks, code decides the numbers
- Totals and charts come **only from SQL**. Tool results carry amounts already formatted by code.
- Any `$` amount in an AI answer that no tool produced is flagged **"Not from your data"**.
- Date anchors ("last month = 2026-10") and the reply language are computed by code, not guessed.
- On a turn that proposes a write, the text is code-written ("Waiting for your confirmation…"), so the model can't claim it already happened.

## Screenshots

| Ask for a chart | Arabic question + confirm card |
|---|---|
| ![](docs/screenshots/ai-chart.png) | ![](docs/screenshots/ai-arabic-confirm.png) |
| **RAG search with citations + period comparison** | **Needs review: items don't match the total** |
| ![](docs/screenshots/ai-search-compare.png) | ![](docs/screenshots/review-mismatch.png) |
| **Arabic invoice, auto-confirmed** | **Phone photo flagged as a duplicate** |
| ![](docs/screenshots/arabic-invoice.png) | ![](docs/screenshots/duplicate-photo.png) |

## Stack

Swift 6 · SwiftUI · Swift Charts · **PostgreSQL 17 + pgvector 0.8.7** · PostgresNIO · Ollama (`qwen3.5:9b` for chat, tools and vision; `qwen3-embedding:0.6b`) · PDFKit · Apple Vision · Apple Speech · CryptoKit · Swift Testing

## Run it

```bash
brew install postgresql@17 pgvector && brew services start postgresql@17
createdb expenses && psql -d expenses -c "CREATE EXTENSION vector"
ollama pull qwen3.5:9b && ollama pull qwen3-embedding:0.6b
scripts/make_app.sh && open build/Expenses.app
```

Set `EXPENSES_PG_URL=postgres://user:pass@host:5432/db` to use another database.

Headless mode (the same pipeline, without the UI):

```bash
build/Expenses.app/Contents/MacOS/ExpensesApp --ingest samples/*.pdf samples/*.png
build/Expenses.app/Contents/MacOS/ExpensesApp --ask "How much did I spend last month?"
build/Expenses.app/Contents/MacOS/ExpensesApp --list
```

## Tests

```bash
createdb expenses_test && psql -d expenses_test -c "CREATE EXTENSION vector"
swift test                                              # 41 tests, one Postgres schema per test
EXPENSES_BENCH=1 swift test -c release --filter Scale   # 1,000,000-row benchmark
scripts/clean_test_schemas.sh
```

The tests cover money and date parsing (including Arabic-Indic digits), each validator rule, aggregates and keyset pagination, frozen rates, undo of every write, full rollback on failure, concurrent writers, 10 concurrent identical uploads → 1 invoice, AI offline → retry, an embedding outage, HNSW ranking, Arabic full-text search, and the assistant's safety guards.

**At 1M rows:** last year by month **18 ms**, by day **20 ms**, one month total **3 ms**, all time by year **56 ms** (an index-only scan on a covering partial index).

## Layout

```
Sources/ExpensesKit/   DB (Postgres pool, schema) · Store · Core (Money, Day) · Ingest · Search · Assistant · AI
Sources/ExpensesApp/   SwiftUI screens, chat panel, speech, charts, CLI
Tests/                 Swift Testing suites
samples/               8 generated invoices with fictional vendors (EN, AR, SAR, KWD, duplicate photo…)
docs/                  build report (HTML + PDF), screenshots
```
