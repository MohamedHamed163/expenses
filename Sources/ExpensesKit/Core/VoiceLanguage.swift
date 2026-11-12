import Foundation

/// Picks the transcription language for a voice command. The app supports
/// Arabic and English only. Whisper's `langProbs` are LOG-probabilities and may
/// contain only the detected language, so a missing language counts as -infinity.
public enum VoiceLanguage {
    public static func choose(detected: String, logProbs: [String: Float]) -> String {
        if detected == "ar" || detected == "en" { return detected }
        let ar = logProbs["ar"] ?? -.infinity, en = logProbs["en"] ?? -.infinity
        if ar == -.infinity && en == -.infinity { return "ar" }   // e.g. Arabic speech misdetected as Persian/Urdu
        return ar >= en ? "ar" : "en"
    }
}
