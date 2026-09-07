import AVFoundation
import Speech

@MainActor
final class VoiceInputController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    var onFinished: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isListening {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isListening else { return }
        errorMessage = nil
        transcript = ""

        guard await authorizeSpeech() else {
            errorMessage = "Allow Speech Recognition in System Settings to use dictation."
            return
        }
        guard await authorizeMicrophone() else {
            errorMessage = "Allow microphone access in System Settings to use dictation."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is currently unavailable."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.stop() }
                    } else if let error {
                        self.errorMessage = error.localizedDescription
                        self.stop()
                    }
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            errorMessage = "The microphone could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isListening || request != nil else { return }
        let completedTranscript = transcript
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        if !completedTranscript.isEmpty { onFinished?(completedTranscript) }
    }

    private func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private func authorizeMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    deinit {
        if engine.isRunning { engine.stop() }
    }
}
