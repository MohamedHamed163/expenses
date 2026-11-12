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
                        Button { model.showChat = true } label: {
                            HStack(spacing: 8) {
                                WalletLogo(size: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(Brand.name).font(.callout.weight(.semibold))
                                    HStack(spacing: 4) {
                                        Circle().fill(model.aiOnline ? Brand.emerald : .orange).frame(width: 6, height: 6)
                                        Text(model.aiOnline ? "Online" : "Offline").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }.buttonStyle(.plain).padding(10)
                    }
                } detail: {
                    detail
                }
                .inspector(isPresented: $model.showChat) {
                    ChatPanel().inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
                .toolbar {
                    ToolbarItem {
                        Button { Task { await model.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .keyboardShortcut("z", modifiers: .command).help("Undo the last change (⌘Z)")
                    }
                    ToolbarItem {
                        Button { model.showChat.toggle() } label: { Label("Ask \(Brand.name)", systemImage: "wallet.bifold") }
                            .keyboardShortcut("k", modifiers: .command).help("Ask \(Brand.name) (⌘K)")
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
        .tint(Brand.accent)
        .frame(minWidth: 1040, minHeight: 700)
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
    @State private var voice = VoiceInput()
    @FocusState private var focused: Bool

    static let suggestions: [(String, String)] = [
        ("chart.bar.fill", "Show last year's expenses by month"),
        ("arrow.left.arrow.right", "Compare October vs September"),
        ("magnifyingglass", "Which invoice had olive oil?"),
        ("character.bubble", "كم صرفت على البقالة الشهر اللي فات؟"),
    ]

    var hasConversation: Bool { model.chat.contains { $0.role != .notice } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if hasConversation { conversation } else { welcome }
            Divider()
            composer
        }
        .background(Brand.emerald.opacity(0.025))
        .task {
            voice.onTranscript = { text in Task { await model.send(text, viaVoice: true) } }
            await voice.warmUpIfDownloaded()
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            WalletLogo(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name).font(.headline)
                Text(model.aiOnline ? "Online · private, on this Mac" : "Offline · start Ollama")
                    .font(.caption).foregroundStyle(model.aiOnline ? Brand.emerald : .orange)
            }
            Spacer()
            if hasConversation {
                Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New conversation")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var welcome: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 18)
                WalletLogo(size: 64)
                VStack(spacing: 4) {
                    Text("Hello, I'm \(Brand.name)").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(Brand.tagline.prefix(1).uppercased() + Brand.tagline.dropFirst()).foregroundStyle(.secondary)
                    Text("أهلاً، أنا \(Brand.name)، \(Brand.taglineAR)").font(.callout).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                .multilineTextAlignment(.center)
                VoiceButton(voice: voice, size: 76) { Task { await voice.toggle() } }
                Text(voice.state.caption).font(.callout).foregroundStyle(voice.state == .listening ? .red : .secondary)
                if let err = voice.error { Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
                VStack(spacing: 8) {
                    Text("Or try").font(.caption).foregroundStyle(.tertiary)
                    ForEach(Self.suggestions, id: \.1) { icon, text in
                        Button { Task { await model.send(text) } } label: {
                            Label(text, systemImage: icon).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.emerald.opacity(0.25)))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .padding(18)
        }
    }

    var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.chat.filter { $0.role != .notice || $0.text.hasPrefix("AI offline") || $0.text.hasPrefix("Error") }) { item in
                        ChatBubble(item: item).id(item.id)
                    }
                    if model.thinking {
                        HStack(spacing: 8) { WalletLogo(size: 22); ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                            .id("thinking")
                    }
                }.padding(12)
            }
            .onChange(of: model.chat.count) { withAnimation { proxy.scrollTo(model.chat.last?.id, anchor: .bottom) } }
            .onChange(of: model.thinking) { if model.thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasConversation, voice.state != .idle || voice.error != nil {
                Text(voice.error ?? voice.state.caption).font(.caption)
                    .foregroundStyle(voice.error != nil ? .red : voice.state == .listening ? .red : .secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask \(Brand.name)…  (Return to send)", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).focused($focused)
                    .onSubmit { send() }
                    .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.emerald.opacity(focused ? 0.6 : 0.15)))
                if hasConversation {
                    VoiceButton(voice: voice, size: 30) { Task { await voice.toggle() } }
                        .frame(width: 40, height: 40)
                }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(Brand.gradient) }
                    .buttonStyle(.plain).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.thinking)
                    .keyboardShortcut(.return, modifiers: .command)
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
            HStack(alignment: .bottom) {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.text).padding(10).foregroundStyle(.white)
                        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                    if item.viaVoice { Label("Voice", systemImage: "waveform").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        case .notice:
            Label(item.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                WalletLogo(size: 24)
                assistantBody
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.text.isEmpty { Text(.init(item.text)).textSelection(.enabled) }
            if !item.unverified.isEmpty {
                Label("Not from your data: \(item.unverified.joined(separator: ", ")). Check the chart/table.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(item.charts) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.title).font(.caption.weight(.semibold))
                    SpendChart(rows: c.rows, kind: c.kind, height: 150, maxLabels: 4)
                    Text("Total \(Money.format(c.totalUSDMinor))").font(.caption).foregroundStyle(.secondary)
                }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(item.tables) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.caption.weight(.semibold))
                    ForEach(t.rows.prefix(12)) { r in
                        HStack { Text(r.label).font(.caption); Spacer(); Text(Money.format(r.usdMinor)).font(.caption.monospacedDigit()) }
                    }
                }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
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
