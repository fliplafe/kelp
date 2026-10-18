import AVFoundation
import Speech

/// On-device speech-to-text for prompts. Nothing is sent to a server (requiresOnDeviceRecognition).
@MainActor
final class Dictation {
    static let shared = Dictation()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRecording = false
    private(set) var text = ""
    var onUpdate: ((String) -> Void)?

    /// Usage strings live in the app bundle's Info.plist; without them macOS would kill the process on mic access.
    var isSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    func start() async throws {
        guard isSupported else { throw NSError(domain: "Krill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dictation needs the Krill app bundle (microphone permission)."]) }
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { throw NSError(domain: "Krill", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is not allowed. Enable it in System Settings › Privacy & Security."]) }
        guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable else {
            throw NSError(domain: "Krill", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable for this language."])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req; text = ""
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare(); try engine.start()
        isRecording = true
        task = rec.recognitionTask(with: req) { [weak self] r, _ in
            guard let r else { return }
            let t = r.bestTranscription.formattedString
            Task { @MainActor in self?.text = t; self?.onUpdate?(t) }
        }
    }

    /// Stops and returns the final transcript.
    func stop() -> String {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.finish()
        isRecording = false
        return text
    }
}
