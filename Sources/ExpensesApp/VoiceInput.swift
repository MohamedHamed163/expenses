import Foundation
import AVFoundation
import WhisperKit
import ExpensesKit

/// Tap-to-talk voice input, transcribed fully on-device by Whisper (WhisperKit,
/// Core ML / Neural Engine). Arabic (incl. Egyptian) and English are detected
/// automatically; audio never leaves the Mac.
@MainActor @Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case preparing(String)          // downloading / loading the model
        case listening
        case transcribing
    }

    nonisolated static let model = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let maxSeconds: Double = 30

    var state: State = .idle
    var level: Float = 0               // 0…1 mic level for the animation
    var error: String?
    var lastLanguage: String?

    /// Called with the final transcript (already trimmed, non-empty).
    var onTranscript: ((String) -> Void)?

    private var whisper: WhisperKit?
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    /// Read on the audio thread; written only while the tap is not installed.
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    private var startedAt = Date()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var isBusy: Bool { state != .idle }

    nonisolated static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Expenses/voice-models", isDirectory: true)
    }

    /// Tap the mic: start listening; tap again: stop and transcribe.
    func toggle() async {
        switch state {
        case .idle: await start()
        case .listening: await stopAndTranscribe()
        default: break
        }
    }

    /// Loads the model in the background if it is already downloaded, so the first tap is instant.
    func warmUpIfDownloaded() async {
        guard whisper == nil, let folder = Self.downloadedModelFolder() else { return }
        whisper = try? await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
    }

    nonisolated static func downloadedModelFolder() -> URL? {
        let folder = modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path) ? folder : nil
    }

    private func ensureModel() async throws -> WhisperKit {
        if let whisper { return whisper }
        var folder = Self.downloadedModelFolder()
        if folder == nil {
            state = .preparing("Downloading voice model… (one time, ~630 MB)")
            folder = try await WhisperKit.download(variant: Self.model, downloadBase: Self.modelsDir) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                Task { @MainActor in self.state = .preparing("Downloading voice model… \(pct)% (one time)") }
            }
        }
        state = .preparing("Loading voice model…")
        let w = try await WhisperKit(WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        whisper = w
        return w
    }

    private func start() async {
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        do { _ = try await ensureModel() } catch {
            state = .idle
            self.error = "Couldn't prepare the voice model: \(error.localizedDescription)"
            return
        }
        samples = []
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let (chunk, rms) = self.convert(buffer)
            Task { @MainActor in
                self.samples.append(contentsOf: chunk)
                self.level = min(1, rms * 8)
                if Date().timeIntervalSince(self.startedAt) > Self.maxSeconds { await self.stopAndTranscribe() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Microphone error: \(error.localizedDescription)"
            state = .idle
            return
        }
        startedAt = Date()
        state = .listening
    }

    /// Shared by the app and the `--transcribe` CLI. Restricts the language to the
    /// app's two: Arabic or English, whichever Whisper rates more likely.
    nonisolated static func transcribe(_ audio: [Float], with w: WhisperKit) async throws -> (text: String, language: String) {
        let detected = try await w.detectLangauge(audioArray: audio)
        if ProcessInfo.processInfo.environment["VOICE_DEBUG"] == "1" {
            let top = detected.langProbs.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
            print("detected=\(detected.language) top=\(top)")
        }
        let lang = VoiceLanguage.choose(detected: detected.language, logProbs: detected.langProbs)
        let options = DecodingOptions(task: .transcribe, language: lang, temperature: 0, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await w.transcribe(audioArray: audio, decodeOptions: options)
        return (results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), lang)
    }

    /// Headless: download/load the model and transcribe a file (used by tests and the CLI).
    nonisolated static func transcribeFile(_ path: String) async throws -> (text: String, language: String, seconds: Double) {
        var folder = downloadedModelFolder()
        if folder == nil {
            print("downloading \(model)…")
            folder = try await WhisperKit.download(variant: model, downloadBase: modelsDir)
        }
        let w = try await WhisperKit(WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let t = Date()
        let r = try await transcribe(audio, with: w)
        return (r.text, r.language, Date().timeIntervalSince(t))
    }

    nonisolated private func convert(_ buffer: AVAudioPCMBuffer) -> ([Float], Float) {
        // Runs on the audio thread: resample to 16 kHz mono float.
        guard let converter = self.converter else { return ([], 0) }
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return ([], 0) }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData?[0] else { return ([], 0) }
        let arr = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        let rms = arr.isEmpty ? 0 : sqrt(arr.reduce(0) { $0 + $1 * $1 } / Float(arr.count))
        return (arr, rms)
    }

    private func stopAndTranscribe() async {
        guard state == .listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        let audio = samples
        samples = []
        guard audio.count > 16_000 / 3 else { state = .idle; return }   // < 0.33 s: ignore accidental taps
        state = .transcribing
        do {
            let w = try await ensureModel()
            state = .transcribing
            let (text, lang) = try await Self.transcribe(audio, with: w)
            lastLanguage = lang
            state = .idle
            if text.isEmpty { error = "I didn't catch that. Try again a bit closer to the mic." }
            else { onTranscript?(text) }
        } catch {
            state = .idle
            self.error = "Transcription failed: \(error.localizedDescription)"
        }
    }
}
