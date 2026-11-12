import SwiftUI

/// Wallet: the assistant's identity. Emerald → teal: money, calm, trustworthy.
enum Brand {
    static let name = "Wallet"
    static let tagline = "your personal financial assistant"
    static let taglineAR = "مساعدك المالي الشخصي"
    static let emerald = Color(red: 0.06, green: 0.73, blue: 0.51)   // #10B981
    static let teal = Color(red: 0.05, green: 0.58, blue: 0.70)      // #0E94B3
    static let gold = Color(red: 0.98, green: 0.75, blue: 0.24)      // #FABF3D
    static let accent = emerald
    static let gradient = LinearGradient(colors: [emerald, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The Wallet mark: a wallet glyph on the brand gradient with a gold coin.
struct WalletLogo: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Brand.gradient)
            Image(systemName: "wallet.bifold.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
            Circle().fill(Brand.gold)
                .overlay(Text("$").font(.system(size: size * 0.17, weight: .heavy, design: .rounded)).foregroundStyle(.white))
                .frame(width: size * 0.3, height: size * 0.3)
                .offset(x: size * 0.3, y: -size * 0.3)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: Brand.teal.opacity(0.35), radius: size * 0.12, y: size * 0.05)
        .accessibilityLabel("Wallet")
    }
}

/// The big round voice button with level-reactive rings.
struct VoiceButton: View {
    let voice: VoiceInput
    var size: CGFloat = 76
    let action: () -> Void
    @State private var pulse = false

    var listening: Bool { voice.state == .listening }
    var disabled: Bool {
        if case .preparing = voice.state { return true }
        return voice.state == .transcribing
    }

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
            .disabled(disabled)
            .animation(.easeOut(duration: 0.12), value: voice.level)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            .help(listening ? "Tap to stop and send" : "Tap to talk (Arabic or English)")
    }

    var content: some View {
        ZStack {
            if listening { rings }
            disc
            glyph
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .contentShape(Circle())
    }

    var rings: some View {
        ForEach(0..<3, id: \.self) { i in
            let scale: CGFloat = 1 + CGFloat(voice.level) * 0.6 + CGFloat(i) * 0.18 + (pulse ? 0.06 : 0)
            Circle()
                .stroke(Brand.emerald.opacity(0.35 - Double(i) * 0.1), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(scale)
        }
    }

    @ViewBuilder var disc: some View {
        let glow: Color = listening ? .red : Brand.teal
        if listening {
            Circle().fill(Color.red.gradient).frame(width: size, height: size)
                .shadow(color: glow.opacity(0.4), radius: 10, y: 4)
        } else {
            Circle().fill(Brand.gradient).frame(width: size, height: size)
                .shadow(color: glow.opacity(0.4), radius: 10, y: 4)
        }
    }

    @ViewBuilder var glyph: some View {
        switch voice.state {
        case .idle: icon("mic.fill")
        case .listening: icon("stop.fill")
        case .preparing, .transcribing: ProgressView().controlSize(.small).tint(.white)
        }
    }

    func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white)
    }
}

extension VoiceInput.State {
    var caption: String {
        switch self {
        case .idle: return "Tap to talk · Arabic or English"
        case .preparing(let s): return s
        case .listening: return "Listening… tap to stop"
        case .transcribing: return "Transcribing on your Mac…"
        }
    }
}
