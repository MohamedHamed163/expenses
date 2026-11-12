import SwiftUI
import ExpensesKit

struct RootView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let err = model.databaseError {
                ContentUnavailableView {
                    Label("Can't reach Postgres", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Expenses stores everything in a local Postgres 17 + pgvector database.\nStart it with:  brew services start postgresql@17\n\n\(err)")
                        .multilineTextAlignment(.center)
                } actions: {
                    Button("Retry") { Task { await model.start() } }
                }
            } else if !model.ready {
                ProgressView("Connecting to Postgres…")
            } else {
                NavigationSplitView {
                    List(selection: $model.screen) {
                        Label("Dashboard", systemImage: "square.grid.2x2").tag(Screen.dashboard)
                        Label("Invoices", systemImage: "doc.text").badge(model.counts[.proposed] ?? 0).tag(Screen.invoices)
                        Label("Analytics", systemImage: "chart.bar.xaxis").tag(Screen.analytics)
                        Label("Expenses", systemImage: "list.bullet.rectangle").tag(Screen.expenses)
                        Label("Settings", systemImage: "gearshape").tag(Screen.settings)
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 6) {
                            Circle().fill(model.aiOnline ? .green : .orange).frame(width: 8, height: 8)
                            Text(model.aiOnline ? "Local AI online" : "AI offline").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(10)
                    }
                } detail: {
                    detail
                }
                .inspector(isPresented: $model.showChat) {
                    ChatPanel().inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
                .toolbar {
                    ToolbarItem {
                        Button { Task { await model.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .keyboardShortcut("z", modifiers: .command).help("Undo the last change (⌘Z)")
                    }
                    ToolbarItem {
                        Button { model.showChat.toggle() } label: { Label("Ask AI", systemImage: "bubble.left.and.text.bubble.right") }
                            .keyboardShortcut("k", modifiers: .command).help("Ask AI (⌘K)")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
        .frame(minWidth: 1280, minHeight: 760)
    }

    @ViewBuilder var detail: some View {
        switch model.screen {
        case .dashboard: DashboardView()
        case .invoices, .review: InvoicesView()
        case .analytics: AnalyticsView()
        case .expenses: ExpensesListView()
        case .settings: SettingsView()
        }
    }
}

struct ChatPanel: View {
    @Environment(AppModel.self) var model
    @State private var input = ""
    @State private var speech = SpeechInput()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Ask AI", systemImage: "sparkles").font(.headline)
                Spacer()
                Text("on-device").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }.padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.chat) { item in ChatBubble(item: item).id(item.id) }
                        if model.thinking {
                            HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }.id("thinking")
                        }
                    }.padding(12)
                }
                .onChange(of: model.chat.count) { withAnimation { proxy.scrollTo(model.chat.last?.id, anchor: .bottom) } }
            }
            Divider()
            composer
        }
        .onChange(of: speech.transcript) { if !speech.transcript.isEmpty { input = speech.transcript } }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = speech.error { Text(err).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(speech.isRecording ? "Listening…" : "Ask or command… (Return to send)", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).focused($focused)
                    .onSubmit { send() }
                    .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $speech.language) {
                    Text("ع").tag("ar-EG")
                    Text("EN").tag("en-US")
                }.pickerStyle(.segmented).frame(width: 74).help("Voice language")
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.title3).foregroundStyle(speech.isRecording ? .red : .accentColor)
                    .frame(width: 32, height: 32)
                    .background(speech.isRecording ? Color.red.opacity(0.15) : Color.clear, in: Circle())
                    .help("Hold to talk")
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !speech.isRecording { Task { await speech.start() } } }
                        .onEnded { _ in speech.stop(); focused = true })
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.thinking)
            }
        }.padding(12)
    }

    func send() {
        let text = input
        input = ""
        Task { await model.send(text) }
    }
}

struct ChatBubble: View {
    @Environment(AppModel.self) var model
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack { Spacer(minLength: 40); Text(item.text).padding(10).background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)).textSelection(.enabled) }
        case .notice:
            Text(item.text).font(.callout).foregroundStyle(.secondary).padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                if !item.unverified.isEmpty {
                    Label("Not from your data: \(item.unverified.joined(separator: ", ")). Check the chart/table.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(item.charts) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title).font(.caption.weight(.semibold))
                        SpendChart(rows: c.rows, kind: c.kind, height: 160)
                        Text("Total \(Money.format(c.totalUSDMinor))").font(.caption).foregroundStyle(.secondary)
                    }.padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(item.tables) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).font(.caption.weight(.semibold))
                        ForEach(t.rows.prefix(12)) { r in
                            HStack { Text(r.label).font(.caption); Spacer(); Text(Money.format(r.usdMinor)).font(.caption.monospacedDigit()) }
                        }
                    }.padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(item.pending) { p in ConfirmCard(action: p, state: item.actionStates[p.id] ?? .waiting, itemID: item.id) }
                if !item.citations.isEmpty {
                    HStack(spacing: 6) {
                        Text("Sources:").font(.caption).foregroundStyle(.secondary)
                        ForEach(item.citations, id: \.self) { id in
                            Button("#\(id)") { model.openCitation(id) }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                if !item.trace.isEmpty {
                    DisclosureGroup("Tools used (\(item.trace.count))") {
                        ForEach(item.trace, id: \.self) { Text($0).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.font(.caption)
                }
            }
            .padding(10)
            .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ConfirmCard: View {
    @Environment(AppModel.self) var model
    let action: PendingAction
    let state: ChatItem.ActionState
    let itemID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(action.summary, systemImage: "hand.raised").font(.callout)
            switch state {
            case .waiting:
                HStack {
                    Button("Confirm") { Task { await model.resolve(action, in: itemID, confirm: true) } }.buttonStyle(.borderedProminent)
                    Button("Cancel") { Task { await model.resolve(action, in: itemID, confirm: false) } }
                }
            case .done(let msg): Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
            case .failed(let e): Label(e, systemImage: "exclamationmark.octagon").foregroundStyle(.red).font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
    }
}
