import Foundation
import Speech
import AVFoundation

/// Push-to-talk speech input, transcribed on-device by Apple Speech.
/// The transcript goes into the chat box; the user sends it with Return,
/// so a misheard command is visible before anything runs.
@MainActor @Observable
final class SpeechInput {
    var isRecording = false
    var transcript = ""
    var error: String?
    var language: String = "ar-EG"    // toggled AR / EN in the chat panel

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isRecording else { return }
        error = nil
        transcript = ""
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { error = "Speech recognition permission denied (System Settings › Privacy › Speech Recognition)."; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Microphone permission denied."; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            error = "Speech recognition for \(language) is not available on this Mac."; return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true     // agreed: audio never leaves the Mac
        } else {
            error = "On-device recognition for \(language) isn't installed. Add it under System Settings › Keyboard › Dictation."
            return
        }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { self.error = "Audio engine: \(error.localizedDescription)"; return }
        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if err != nil || result?.isFinal == true { self.teardown() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }

    private func teardown() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        isRecording = false
        task = nil
        request = nil
    }
}
