import AVFoundation
import Foundation
import OSLog

@MainActor
final class RealtimeVoiceController: ObservableObject {
    enum State: Equatable {
        case idle, connecting, listening, thinking, speaking

        var title: String {
            switch self {
            case .idle: return "Start voice conversation"
            case .connecting: return "Connecting…"
            case .listening: return "Listening"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var audioNotice: String?

    var isActive: Bool { state != .idle }

    private let logger = Logger(subsystem: "dev.sora.app", category: "RealtimeVoice")
    private var capturedAudioBuffers = 0
    private var engine = AVAudioEngine()
    private var captureEngine: AVAudioEngine?
    private var player = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var transport: RealtimeVoiceTransport?
    private var receiveTask: Task<Void, Never>?
    private var inputTapInstalled = false
    private var userMessages: [String: UUID] = [:]
    private var userTranscripts: [String: String] = [:]
    private var assistantMessages: [String: UUID] = [:]
    private var assistantTranscripts: [String: String] = [:]
    private var currentAssistantItemID: String?
    private var assistantStartSampleTime: AVAudioFramePosition?
    private var receivedAssistantAudioByteCount = 0
    private var assistantAudioStreamFinished = false
    private var scheduledAudioBuffers = 0
    private var playbackFormat: AVAudioFormat?
    private var playbackConverter: AVAudioConverter?
    private var usesVoiceProcessing = false
    private var playbackGeneration = UUID()
    private var captureGeneration = UUID()
    private var captureWatchdog: Task<Void, Never>?
    private var captureHealth = RealtimeCaptureHealth()
    private var configurationObservers: [NSObjectProtocol] = []
    private var audioRecoveryTask: Task<Void, Never>?
    private var audioRecoveryAttempts = 0


    private var onBeginMessage: ((AIMessage.Role) -> UUID)?
    private var onUpdateMessage: ((UUID, String, Bool) -> Void)?
    private var onStopMessage: ((UUID) -> Void)?

    func start(
        apiKey: String,
        model: String,
        onBeginMessage: @escaping (AIMessage.Role) -> UUID,
        onUpdateMessage: @escaping (UUID, String, Bool) -> Void,
        onStopMessage: @escaping (UUID) -> Void
    ) async {
        guard state == .idle else { return }
        errorMessage = nil
        guard await authorizeMicrophone() else {
            errorMessage = "Allow microphone access in System Settings to use realtime voice."
            return
        }

        self.onBeginMessage = onBeginMessage
        self.onUpdateMessage = onUpdateMessage
        self.onStopMessage = onStopMessage
        state = .connecting
        audioRecoveryAttempts = 0

        do {
            try prepareAudio()
            let transport = try RealtimeVoiceTransport(apiKey: apiKey, model: model)
            self.transport = transport
            await transport.connect()
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let event = try await transport.receive()
                        try Task.checkCancellation()
                        await self?.handle(event, transport: transport)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    func stop() {
        guard state != .idle || transport != nil else { return }
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            Task { await transport.close() }
        }
        transport = nil
        audioRecoveryTask?.cancel()
        audioRecoveryTask = nil
        stopAudio()
        finishOpenMessages()
        resetConversationState()
        state = .idle
    }

    private func handle(_ event: [String: Any], transport: RealtimeVoiceTransport) async {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session.created":
            do {
                try await transport.configureSession()
            } catch { fail(error) }
        case "session.updated":
            do {
                try startAudio(using: transport)
                if audioRecoveryTask == nil { state = .listening }
            } catch { fail(error) }
        case "input_audio_buffer.speech_started":
            if RealtimeVoiceTiming.shouldInterruptPlayback(
                isSpeaking: state == .speaking,
                scheduledAudioBuffers: scheduledAudioBuffers
            ) {
                await interruptPlayback(using: transport)
            }
            state = .listening
        case "input_audio_buffer.speech_stopped":
            state = .thinking
        case "conversation.item.input_audio_transcription.delta":
            updateTranscript(event, role: .user, completed: false)
        case "conversation.item.input_audio_transcription.completed":
            updateTranscript(event, role: .user, completed: true)
        case "response.output_item.added":
            if let item = event["item"] as? [String: Any], let id = item["id"] as? String {
                selectAssistantAudioItem(id)
            }
        case "response.output_audio.delta":
            guard let encoded = event["delta"] as? String,
                  let data = Data(base64Encoded: encoded) else { return }
            if let id = event["item_id"] as? String { selectAssistantAudioItem(id) }
            assistantAudioStreamFinished = false
            receivedAssistantAudioByteCount += data.count
            play(data)
            state = .speaking
        case "response.output_audio.done":
            assistantAudioStreamFinished = true
            finishAssistantPlaybackIfReady()
        case "response.output_audio_transcript.delta":
            updateTranscript(event, role: .assistant, completed: false)
        case "response.output_audio_transcript.done":
            updateTranscript(event, role: .assistant, completed: true)
        case "response.done":
            assistantAudioStreamFinished = true
            finishAssistantPlaybackIfReady()
        case "error":
            let detail = (event["error"] as? [String: Any])?["message"] as? String
                ?? "The voice service returned an error."
            fail(RealtimeVoiceError.server(detail))
        default:
            break
        }
    }

    private func updateTranscript(_ event: [String: Any], role: AIMessage.Role, completed: Bool) {
        let itemID = event["item_id"] as? String ?? (role == .assistant ? currentAssistantItemID : nil) ?? UUID().uuidString
        let finalText = event["transcript"] as? String
        let delta = event["delta"] as? String ?? ""
        if role == .user {
            let messageID = userMessages[itemID] ?? beginMessage(role: role, itemID: itemID)
            let text = finalText ?? (userTranscripts[itemID, default: ""] + delta)
            userTranscripts[itemID] = text
            onUpdateMessage?(messageID, text, completed)
            if completed {
                userMessages.removeValue(forKey: itemID)
                userTranscripts.removeValue(forKey: itemID)
            }
        } else {
            let messageID = assistantMessages[itemID] ?? beginMessage(role: role, itemID: itemID)
            let text = finalText ?? (assistantTranscripts[itemID, default: ""] + delta)
            assistantTranscripts[itemID] = text
            onUpdateMessage?(messageID, text, completed)
            if completed {
                assistantMessages.removeValue(forKey: itemID)
                assistantTranscripts.removeValue(forKey: itemID)
            }
        }
    }

    private func beginMessage(role: AIMessage.Role, itemID: String) -> UUID {
        let id = onBeginMessage?(role) ?? UUID()
        if role == .user { userMessages[itemID] = id }
        else { assistantMessages[itemID] = id }
        return id
    }

    private func prepareAudio() throws {
        // VoiceProcessingIO currently faults on the active macOS routes and
        // leaves aggregate-device reconfiguration behind. Start with isolated
        // raw capture/playback until that path has hardware-level validation.
        try configureAudioGraph(voiceProcessing: false)
    }

    private func configureAudioGraph(voiceProcessing: Bool) throws {
        let nextEngine = AVAudioEngine()
        let nextPlayer = AVAudioPlayerNode()
        if voiceProcessing {
            try nextEngine.inputNode.setVoiceProcessingEnabled(true)
            nextEngine.inputNode.isVoiceProcessingInputMuted = false
            nextEngine.inputNode.isVoiceProcessingBypassed = false
        }
        // Raw duplex audio must not create an aggregate device coupling
        // microphone and speaker clocks. Use an input-only engine in fallback.
        let nextCaptureEngine = voiceProcessing ? nextEngine : AVAudioEngine()
        let captureFormat = nextCaptureEngine.inputNode.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
            throw RealtimeVoiceError.audioFailed("No microphone input is available.")
        }
        let outputFormat = nextEngine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: pcmFormat, to: outputFormat) else {
            throw RealtimeVoiceError.audioFailed("The speaker format is unsupported.")
        }
        // Capture and playback have separate converters; mono microphones and
        // stereo speakers do not need matching hardware formats.
        nextEngine.attach(nextPlayer)
        nextEngine.connect(nextPlayer, to: nextEngine.mainMixerNode, format: outputFormat)
        nextEngine.connect(nextEngine.mainMixerNode, to: nextEngine.outputNode, format: outputFormat)
        engine = nextEngine
        captureEngine = nextCaptureEngine
        player = nextPlayer
        playbackFormat = outputFormat
        playbackConverter = converter
        let observedEngines = voiceProcessing ? [nextEngine] : [nextEngine, nextCaptureEngine]
        configurationObservers = observedEngines.map { observedEngine in
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: .main
            ) { [weak self, weak observedEngine] _ in
                Task { @MainActor [weak self, weak observedEngine] in
                    guard let self, let observedEngine,
                          self.engine === observedEngine || self.captureEngine === observedEngine,
                          self.transport != nil,
                          !observedEngine.isRunning else { return }
                    self.scheduleAudioRecovery()
                }
            }
        }
        usesVoiceProcessing = voiceProcessing && nextEngine.inputNode.isVoiceProcessingEnabled
        audioNotice = usesVoiceProcessing ? nil
            : "Echo cancellation unavailable. Use headphones to prevent speaker feedback."

    }

    private func startAudio(using transport: RealtimeVoiceTransport) throws {
        // session.updated can arrive while an initial device change is being
        // recovered. Do not install a tap on the engine being retired.
        guard audioRecoveryTask == nil else { return }
        do {
            try startConfiguredAudio(using: transport)
        } catch {
            guard usesVoiceProcessing else { throw error }
            scheduleAudioRecovery()
        }
    }

    private func startConfiguredAudio(using transport: RealtimeVoiceTransport) throws {
        guard !inputTapInstalled else { return }
        guard let captureEngine else {
            throw RealtimeVoiceError.audioFailed("The microphone engine is unavailable.")
        }
        let input = captureEngine.inputNode
        // A raw input node's client output format can lag a hardware route
        // change. Install the tap at the hardware format, then convert to PCM.
        let inputFormat = usesVoiceProcessing
            ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw RealtimeVoiceError.audioFailed("The microphone format is unsupported.")
        }
        let generation = UUID()
        captureGeneration = generation
        captureHealth = RealtimeCaptureHealth()
        capturedAudioBuffers = 0
        let wireFormat = pcmFormat
        input.installTap(onBus: 0, bufferSize: 1_200, format: inputFormat) { [weak self] buffer, _ in
            let ratio = 24_000 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil else {
                let reason = conversionError?.localizedDescription ?? "Microphone audio conversion failed."
                Task { @MainActor [weak self] in
                    guard let self, self.captureGeneration == generation else { return }
                    self.fail(RealtimeVoiceError.audioFailed(reason))
                }
                return
            }
            guard converted.frameLength > 0,
                  let bytes = converted.audioBufferList.pointee.mBuffers.mData else { return }
            let data = Data(bytes: bytes, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
            let hasSignal = data.contains { $0 != 0 }
            Task { @MainActor [weak self] in
                guard let self, self.captureGeneration == generation else { return }
                self.capturedAudioBuffers += 1
                if self.capturedAudioBuffers == 1 {
                    self.logger.info("Microphone PCM capture started; voice processing: \(self.usesVoiceProcessing)")
                }
                self.captureHealth.record(hasSignal: hasSignal)
                do {
                    try await transport.sendAudio(data)
                } catch {
                    guard self.captureGeneration == generation else { return }
                    self.fail(error)
                }
            }
        }
        inputTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            if captureEngine !== engine {
                captureEngine.prepare()
                try captureEngine.start()
            }
        }
        catch {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
            throw RealtimeVoiceError.audioFailed(error.localizedDescription)
        }
        captureWatchdog?.cancel()
        captureWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.captureGeneration == generation else { return }
            switch self.captureHealth.action(usesVoiceProcessing: self.usesVoiceProcessing) {
            case .retryWithoutVoiceProcessing:
                // Voice processing may start successfully but fault on its first
                // render. Recover based on delivered PCM, not engine.isRunning.
                self.scheduleAudioRecovery()
            case .captureFailed:
                self.fail(RealtimeVoiceError.audioFailed(
                    "Audio capture did not start. Try reconnecting your microphone and starting voice again."
                ))
            case .healthy:
                break
            }
        }
    }

    private func scheduleAudioRecovery() {
        guard let transport, audioRecoveryTask == nil else { return }
        guard audioRecoveryAttempts < 3 else {
            fail(RealtimeVoiceError.audioFailed("Sora could not stabilize audio capture after three attempts. End voice and try again."))
            return
        }
        audioRecoveryAttempts += 1
        logger.notice("Recovering audio route, attempt \(self.audioRecoveryAttempts); captured buffers: \(self.capturedAudioBuffers)")
        stopAudio()
        // Disabling voice processing tears down its aggregate device. Do this
        // BEFORE creating the replacement engine, then let route changes settle.
        do {
            if usesVoiceProcessing && engine.inputNode.isVoiceProcessingEnabled {
                try engine.inputNode.setVoiceProcessingEnabled(false)
            }
        } catch {
            fail(RealtimeVoiceError.audioFailed(error.localizedDescription))
            return
        }
        state = .connecting
        audioRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.transport === transport else { return }
            self.audioRecoveryTask = nil
            do {
                try self.configureAudioGraph(voiceProcessing: false)
                try self.startConfiguredAudio(using: transport)
                self.state = .listening
            } catch { self.fail(error) }
        }
    }

    private func play(_ data: Data) {
        guard let buffer = convertedPlaybackBuffer(from: data) else { return }
        if assistantStartSampleTime == nil { assistantStartSampleTime = currentPlayerTime()?.sampleTime ?? 0 }
        let generation = playbackGeneration
        scheduledAudioBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.scheduledAudioBuffers = max(0, self.scheduledAudioBuffers - 1)
                self.finishAssistantPlaybackIfReady()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func convertedPlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sourceFrames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard sourceFrames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: sourceFrames),
              let sourceBytes = source.audioBufferList.pointee.mBuffers.mData,
              let playbackFormat,
              let playbackConverter else { return nil }
        source.frameLength = sourceFrames
        data.copyBytes(to: sourceBytes.assumingMemoryBound(to: UInt8.self), count: data.count)

        let ratio = playbackFormat.sampleRate / pcmFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(sourceFrames) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = playbackConverter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil else { return nil }
        return converted
    }

    private func interruptPlayback(using transport: RealtimeVoiceTransport) async {
        let playedMilliseconds: Int?
        if let start = assistantStartSampleTime, let current = currentPlayerTime(),
           current.sampleRate > 0 {
            playedMilliseconds = max(0, Int(Double(current.sampleTime - start) * 1_000 / current.sampleRate))
        } else {
            playedMilliseconds = 0
        }
        playbackGeneration = UUID()
        player.stop()
        player.reset()
        scheduledAudioBuffers = 0
        if let itemID = currentAssistantItemID,
           let playedMilliseconds,
           let audioEndMilliseconds = RealtimeVoiceTiming.truncationMilliseconds(
               playedMilliseconds: playedMilliseconds,
               receivedPCMByteCount: receivedAssistantAudioByteCount
           ) {
            try? await transport.truncate(itemID: itemID, audioEndMilliseconds: audioEndMilliseconds)
        }
        currentAssistantItemID = nil
        assistantStartSampleTime = nil
        receivedAssistantAudioByteCount = 0
        assistantAudioStreamFinished = false

    }

    private func currentPlayerTime() -> AVAudioTime? {
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime) else { return nil }
        return playerTime
    }

    private func selectAssistantAudioItem(_ itemID: String) {
        guard currentAssistantItemID != itemID else { return }
        currentAssistantItemID = itemID
        assistantStartSampleTime = nil
        receivedAssistantAudioByteCount = 0
        assistantAudioStreamFinished = false
    }

    private func finishAssistantPlaybackIfReady() {
        guard assistantAudioStreamFinished, scheduledAudioBuffers == 0 else { return }
        state = .listening
        currentAssistantItemID = nil
        assistantStartSampleTime = nil
        receivedAssistantAudioByteCount = 0
        assistantAudioStreamFinished = false
    }

    private func stopAudio() {
        for observer in configurationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObservers.removeAll()
        captureWatchdog?.cancel()
        captureWatchdog = nil
        captureGeneration = UUID()
        playbackGeneration = UUID()
        player.stop()
        player.reset()
        scheduledAudioBuffers = 0
        if inputTapInstalled {
            captureEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if let captureEngine, captureEngine !== engine, captureEngine.isRunning { captureEngine.stop() }
        if engine.isRunning { engine.stop() }
    }

    private func finishOpenMessages() {
        for id in userMessages.values { onStopMessage?(id) }
        for id in assistantMessages.values { onStopMessage?(id) }
    }

    private func resetConversationState() {
        userMessages.removeAll()
        userTranscripts.removeAll()
        assistantMessages.removeAll()
        assistantTranscripts.removeAll()
        currentAssistantItemID = nil
        assistantStartSampleTime = nil
        receivedAssistantAudioByteCount = 0
        assistantAudioStreamFinished = false
        scheduledAudioBuffers = 0
        playbackFormat = nil
        playbackConverter = nil
        usesVoiceProcessing = false
        audioNotice = nil
        onBeginMessage = nil
        onUpdateMessage = nil
        onStopMessage = nil
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        stop()
    }

    private func authorizeMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    deinit {
        for observer in configurationObservers { NotificationCenter.default.removeObserver(observer) }
        if let captureEngine, captureEngine !== engine, captureEngine.isRunning { captureEngine.stop() }
        audioRecoveryTask?.cancel()
        captureWatchdog?.cancel()
        receiveTask?.cancel()
        if engine.isRunning { engine.stop() }
    }
}

private actor RealtimeVoiceTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let model: String

    init(apiKey: String, model: String) throws {
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw RealtimeVoiceError.connectionFailed
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw RealtimeVoiceError.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        self.session = session
        self.socket = session.webSocketTask(with: request)
        self.model = model
    }

    func connect() { socket.resume() }

    func configureSession() async throws {
        try await send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "instructions": "You are Sora's concise voice assistant for macOS terminal questions. This voice session cannot run commands or use tools. Never claim an action ran. If a terminal action is needed, explain that the user must send it through the typed Agent composer so Sora can apply its normal approval rules.",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-transcribe"],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "marin"
                    ]
                ]
            ]
        ])
    }

    func sendAudio(_ data: Data) async throws {
        // Keep uploading during playback so server VAD can detect interruptions.
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    func truncate(itemID: String, audioEndMilliseconds: Int) async throws {
        try await send([
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": 0,
            "audio_end_ms": audioEndMilliseconds
        ])
    }

    func receive() async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let value): data = value
        @unknown default: throw RealtimeVoiceError.connectionFailed
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeVoiceError.connectionFailed
        }
        return value
    }

    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func send(_ event: [String: Any]) async throws {
        try await socket.send(RealtimeVoiceWireCodec.outboundMessage(for: event))
    }
}
