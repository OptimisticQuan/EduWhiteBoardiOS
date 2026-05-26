@preconcurrency import AVFAudio
import Combine
import CoreMedia
import Foundation
import Speech

enum SpeechTranscriptionError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case unsupportedLocale
    case unavailableOnDevice
    case failedToPrepareAudio
    case timedOut(stage: String)
    case failedToStartCapture(underlying: Error)
    case failedToFinalize(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "未获得语音识别权限。"
        case .microphonePermissionDenied:
            return "未获得麦克风权限。"
        case .unsupportedLocale:
            return "当前设备不支持中文本地转写。"
        case .unavailableOnDevice:
            return "当前设备暂不支持本地 Speech 转写。"
        case .failedToPrepareAudio:
            return "无法准备语音识别资源。"
        case .timedOut(let stage):
            return "语音识别超时：\(stage)。"
        case .failedToStartCapture(let underlying):
            return "启动录音失败：\(underlying.localizedDescription)"
        case .failedToFinalize(let underlying):
            return "整理转写结果失败：\(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class SpeechTranscriptionManager: ObservableObject {
    final class AudioSampleClock: @unchecked Sendable {
        let sampleRate: Double
        var framePosition: AVAudioFramePosition = 0

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
        }
    }

    final class CaptureDiagnostics: @unchecked Sendable {
        var bufferCount = 0
        var totalFrames: AVAudioFramePosition = 0
        var totalOutputFrames: AVAudioFramePosition = 0
        var nonSilentLogCount = 0
        var resultCount = 0
        var lastAveragePowerDB = -160.0
        var lastPeak = 0.0
        var lastOutputFrameLength: AVAudioFrameCount = 0
        var lastInputEndTime: CMTime = .zero
    }

    struct PreparedAnalyzerInput {
        let input: AnalyzerInput
        let outputFrameLength: AVAudioFrameCount
        let startTime: CMTime
        let endTime: CMTime
    }

    struct BackgroundCleanupContext: Sendable {
        let analyzer: SpeechAnalyzer?
        let sessionID: String
        let reason: String
    }

    enum State {
        case idle
        case preparing
        case recording
        case cancelReady
        case finalizing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveText = ""

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<CMTime?, Error>?
    private var audioSampleClock: AudioSampleClock?
    private var bestEffortTranscript = ""
    private var debugSessionID = "--------"
    private var diagnostics: CaptureDiagnostics?
    private var pendingFinishDecision: Bool?
    private var finishDecisionContinuation: CheckedContinuation<Bool, Never>?
    private var completionTask: Task<String?, Error>?

    var isBusy: Bool {
        state != .idle
    }

    var isCancellationArmed: Bool {
        state == .cancelReady
    }

    var buttonTitle: String {
        switch state {
        case .idle:
            return "按住说话"
        case .preparing:
            return "准备中"
        case .recording:
            return "松开发送"
        case .cancelReady:
            return "松开取消"
        case .finalizing:
            return "识别中"
        }
    }

    var secondaryTitle: String {
        switch state {
        case .idle:
            return "本地流式转写"
        case .preparing:
            return "加载模型与权限"
        case .recording:
            return "上滑取消"
        case .cancelReady:
            return "取消当前录音"
        case .finalizing:
            return "正在整理识别结果"
        }
    }

    var hint: String? {
        switch state {
        case .idle:
            return nil
        case .preparing:
            return "正在准备本地语音转写..."
        case .recording:
            return liveText.isEmpty ? "松开发送，上滑取消" : liveText
        case .cancelReady:
            return "松开取消"
        case .finalizing:
            return liveText.isEmpty ? "正在整理转写结果..." : liveText
        }
    }

    func startRecording() async throws {
        guard state == .idle else {
            return
        }

        debugSessionID = String(UUID().uuidString.prefix(8))
        liveText = ""
        bestEffortTranscript = ""
        pendingFinishDecision = nil
        finishDecisionContinuation = nil
        completionTask = nil
        state = .preparing
        let sessionID = debugSessionID
        let diagnostics = CaptureDiagnostics()
        self.diagnostics = diagnostics
        Self.debugPrint(sessionID: sessionID, "startRecording begin")

        do {
            guard await requestSpeechPermission() else {
                Self.debugPrint(sessionID: sessionID, "speech permission denied")
                state = .idle
                throw SpeechTranscriptionError.speechPermissionDenied
            }

            guard await requestMicrophonePermission() else {
                Self.debugPrint(sessionID: sessionID, "microphone permission denied")
                state = .idle
                throw SpeechTranscriptionError.microphonePermissionDenied
            }

            guard SpeechTranscriber.isAvailable else {
                Self.debugPrint(sessionID: sessionID, "SpeechTranscriber unavailable on device")
                state = .idle
                throw SpeechTranscriptionError.unavailableOnDevice
            }

            guard let locale = await resolveLocale() else {
                Self.debugPrint(sessionID: sessionID, "no supported locale resolved")
                state = .idle
                throw SpeechTranscriptionError.unsupportedLocale
            }

            Self.debugPrint(sessionID: sessionID, "resolved locale=\(locale.identifier)")

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Self.debugPrint(sessionID: sessionID, "downloading speech assets")
                try await installationRequest.downloadAndInstall()
                Self.debugPrint(sessionID: sessionID, "speech assets ready")
            }

            try configureAudioSession()
            Self.debugPrint(sessionID: sessionID, "audio session configured")

            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: inputFormat
            ) ?? inputFormat
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            Self.debugPrint(
                sessionID: sessionID,
                "formats input=\(Self.describe(format: inputFormat)) analyzer=\(Self.describe(format: analyzerFormat))"
            )

            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            Self.debugPrint(sessionID: sessionID, "analyzer prepared")

            let stream = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = stream.continuation
            self.audioEngine = audioEngine
            self.analyzer = analyzer
            self.transcriber = transcriber
            audioSampleClock = AudioSampleClock(sampleRate: analyzerFormat.sampleRate)

            resultsTask = Task { [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        diagnostics.resultCount += 1
                        let latestText = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        Self.debugPrint(
                            sessionID: sessionID,
                            "result #\(diagnostics.resultCount) text=\(Self.preview(latestText))"
                        )
                        self?.publishTranscript(latestText)
                    }
                } catch is CancellationError {
                    Self.debugPrint(sessionID: sessionID, "results task cancelled")
                } catch {
                    Self.debugPrint(sessionID: sessionID, "results task failed: \(error.localizedDescription)")
                    self?.publishTranscript("")
                }
            }

            analysisTask = Task {
                Self.debugPrint(sessionID: sessionID, "analyzeSequence started")
                return try await analyzer.analyzeSequence(stream.stream)
            }

            try installTap(
                on: inputNode,
                inputFormat: inputFormat,
                targetFormat: analyzerFormat,
                continuation: stream.continuation,
                sessionID: sessionID,
                diagnostics: diagnostics
            )

            audioEngine.prepare()
            try audioEngine.start()
            Self.debugPrint(sessionID: sessionID, "audio engine started")
            completionTask = Task { @MainActor [weak self] in
                guard let self else {
                    return nil
                }

                return try await self.awaitFinishAndComplete(
                    sessionID: sessionID,
                    diagnostics: diagnostics
                )
            }
            state = pendingFinishDecision == nil ? .recording : .finalizing
        } catch {
            Self.debugPrint(sessionID: sessionID, "startRecording failed: \(error.localizedDescription)")
            await resetPipeline(cancelAnalyzer: true)
            if let speechError = error as? SpeechTranscriptionError {
                throw speechError
            }
            throw SpeechTranscriptionError.failedToStartCapture(underlying: error)
        }
    }

    func setCancellationArmed(_ armed: Bool) {
        switch state {
        case .recording, .cancelReady:
            state = armed ? .cancelReady : .recording
        default:
            break
        }
    }

    func finishRecording(commit: Bool) async throws -> String? {
        guard state != .idle else {
            return nil
        }

        let sessionID = debugSessionID
        Self.debugPrint(
            sessionID: sessionID,
            "finishRecording requested commit=\(commit) live=\(Self.preview(liveText)) fallback=\(Self.preview(bestEffortTranscript))"
        )

        requestFinish(commit: commit)

        while completionTask == nil, state != .idle {
            await Task.yield()
        }

        guard let completionTask else {
            Self.debugPrint(sessionID: sessionID, "finishRecording ended before completion task became available")
            return nil
        }

        return try await completionTask.value
    }

    private func requestFinish(commit: Bool) {
        guard pendingFinishDecision == nil else {
            return
        }

        pendingFinishDecision = commit
        if state != .idle {
            state = .finalizing
        }

        finishDecisionContinuation?.resume(returning: commit)
        finishDecisionContinuation = nil
    }

    private func waitForFinishDecision() async -> Bool {
        if let pendingFinishDecision {
            return pendingFinishDecision
        }

        return await withCheckedContinuation { continuation in
            finishDecisionContinuation = continuation
        }
    }

    private func awaitFinishAndComplete(
        sessionID: String,
        diagnostics: CaptureDiagnostics
    ) async throws -> String? {
        let commit = await waitForFinishDecision()
        return try await completeRecording(
            commit: commit,
            sessionID: sessionID,
            diagnostics: diagnostics
        )
    }

    private func completeRecording(
        commit: Bool,
        sessionID: String,
        diagnostics: CaptureDiagnostics?
    ) async throws -> String? {
        Self.debugPrint(
            sessionID: sessionID,
            "completeRecording begin commit=\(commit) live=\(Self.preview(liveText)) fallback=\(Self.preview(bestEffortTranscript))"
        )

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        if commit {
            state = .finalizing
            do {
                let progressiveText = committedTranscript()
                let reportedLastSampleTime: CMTime?
                do {
                    let waitSeconds = (progressiveText == nil && diagnostics?.resultCount == 0) ? 1.2 : 2.2
                    reportedLastSampleTime = try await Self.withTimeout(seconds: waitSeconds, stage: "等待识别结束") {
                        try await self.analysisTask?.value
                    }
                } catch {
                    if progressiveText == nil,
                       let speechError = error as? SpeechTranscriptionError,
                       case .timedOut = speechError
                    {
                        Self.debugPrint(sessionID: sessionID, "analysis timed out with no transcript; returning nil")
                        let cleanup = detachPipelineForImmediateReturn(
                            sessionID: sessionID,
                            reason: "commit-timeout-no-transcript"
                        )
                        Self.scheduleBackgroundCleanup(cleanup)
                        return nil
                    }
                    throw error
                }
                let finalText = committedTranscript() ?? progressiveText
                Self.debugPrint(
                    sessionID: sessionID,
                    "finishRecording success reported=\(Self.describe(optionalTime: reportedLastSampleTime)) expected=\(Self.describe(optionalTime: diagnostics?.lastInputEndTime)) final=\(Self.preview(finalText ?? "")) \(Self.describe(diagnostics: diagnostics))"
                )
                let cleanup = detachPipelineForImmediateReturn(
                    sessionID: sessionID,
                    reason: finalText == nil ? "commit-empty-after-analysis" : "commit-after-analysis"
                )
                Self.scheduleBackgroundCleanup(cleanup)
                return finalText
            } catch {
                if let progressiveText = committedTranscript() {
                    Self.debugPrint(
                        sessionID: sessionID,
                        "finishRecording recovered from finalize error=\(error.localizedDescription) using progressive=\(Self.preview(progressiveText))"
                    )
                    let cleanup = detachPipelineForImmediateReturn(
                        sessionID: sessionID,
                        reason: "recover-progressive-after-error"
                    )
                    Self.scheduleBackgroundCleanup(cleanup)
                    return progressiveText
                }
                Self.debugPrint(sessionID: sessionID, "finishRecording failed: \(error.localizedDescription)")
                let cleanup = detachPipelineForImmediateReturn(
                    sessionID: sessionID,
                    reason: "finish-failed"
                )
                Self.scheduleBackgroundCleanup(cleanup)
                throw SpeechTranscriptionError.failedToFinalize(underlying: error)
            }
        } else {
            analysisTask?.cancel()
            Self.debugPrint(
                sessionID: sessionID,
                "finishRecording cancelled by user \(Self.describe(diagnostics: diagnostics))"
            )
            let cleanup = detachPipelineForImmediateReturn(
                sessionID: sessionID,
                reason: "cancelled"
            )
            Self.scheduleBackgroundCleanup(cleanup)
            return nil
        }
    }

    private func publishTranscript(_ text: String) {
        liveText = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bestEffortTranscript = text
        }
    }

    private func committedTranscript() -> String? {
        let finalText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            return finalText
        }

        let fallbackText = bestEffortTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackText.isEmpty ? nil : fallbackText
    }

    private func resolveLocale() async -> Locale? {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-Hans")) {
            return locale
        }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) {
            return locale
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    private func requestSpeechPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { nextStatus in
                    continuation.resume(returning: nextStatus == .authorized)
                }
            }
        default:
            return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func installTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        sessionID: String,
        diagnostics: CaptureDiagnostics
    ) throws {
        inputNode.removeTap(onBus: 0)
        let converter = formatsMatch(inputFormat, targetFormat)
            ? nil
            : AVAudioConverter(from: inputFormat, to: targetFormat)

        if !formatsMatch(inputFormat, targetFormat), converter == nil {
            throw SpeechTranscriptionError.failedToPrepareAudio
        }

        guard let audioSampleClock else {
            throw SpeechTranscriptionError.failedToPrepareAudio
        }

        Self.debugPrint(sessionID: sessionID, "installing audio tap")

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            diagnostics.bufferCount += 1
            diagnostics.totalFrames += AVAudioFramePosition(buffer.frameLength)
            let shouldLogBuffer = diagnostics.bufferCount == 1 || diagnostics.bufferCount % 20 == 0

            if shouldLogBuffer, let metrics = Self.audioMetrics(for: buffer) {
                diagnostics.lastAveragePowerDB = metrics.averagePowerDB
                diagnostics.lastPeak = metrics.peak
                if metrics.averagePowerDB > -55 {
                    diagnostics.nonSilentLogCount += 1
                }

                Self.debugPrint(
                    sessionID: sessionID,
                    "tap #\(diagnostics.bufferCount) frames=\(buffer.frameLength) totalFrames=\(diagnostics.totalFrames) avgPowerDB=\(Self.format(metrics.averagePowerDB)) peak=\(Self.format(metrics.peak))"
                )
            } else if shouldLogBuffer {
                Self.debugPrint(
                    sessionID: sessionID,
                    "tap #\(diagnostics.bufferCount) frames=\(buffer.frameLength) totalFrames=\(diagnostics.totalFrames) metrics=unavailable"
                )
            }

            guard let preparedInput = Self.makeAnalyzerInput(
                from: buffer,
                using: converter,
                targetFormat: targetFormat,
                sampleClock: audioSampleClock
            ) else {
                if shouldLogBuffer {
                    Self.debugPrint(sessionID: sessionID, "tap conversion failed")
                }
                return
            }

            diagnostics.lastOutputFrameLength = preparedInput.outputFrameLength
            diagnostics.totalOutputFrames += AVAudioFramePosition(preparedInput.outputFrameLength)
            diagnostics.lastInputEndTime = preparedInput.endTime

            if shouldLogBuffer {
                Self.debugPrint(
                    sessionID: sessionID,
                    "prepared #\(diagnostics.bufferCount) outputFrames=\(preparedInput.outputFrameLength) start=\(Self.describe(time: preparedInput.startTime)) end=\(Self.describe(time: preparedInput.endTime))"
                )
            }

            continuation.yield(preparedInput.input)
        }
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func resetPipeline(cancelAnalyzer: Bool) async {
        if cancelAnalyzer {
            await analyzer?.cancelAndFinishNow()
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        audioSampleClock = nil
        diagnostics = nil
        pendingFinishDecision = nil
        finishDecisionContinuation = nil
        completionTask = nil
        debugSessionID = "--------"

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .idle
        liveText = ""
        bestEffortTranscript = ""
    }

    private func detachPipelineForImmediateReturn(
        sessionID: String,
        reason: String
    ) -> BackgroundCleanupContext {
        let cleanup = BackgroundCleanupContext(
            analyzer: analyzer,
            sessionID: sessionID,
            reason: reason
        )

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        audioSampleClock = nil
        diagnostics = nil
        pendingFinishDecision = nil
        finishDecisionContinuation = nil
        completionTask = nil
        debugSessionID = "--------"

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .idle
        liveText = ""
        bestEffortTranscript = ""
        return cleanup
    }

    private static func makeAnalyzerInput(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        targetFormat: AVAudioFormat,
        sampleClock: AudioSampleClock
    ) -> PreparedAnalyzerInput? {
        guard let nextBuffer = makeAnalyzerBuffer(from: buffer, using: converter, targetFormat: targetFormat) else {
            return nil
        }

        let roundedSampleRate = Int32(sampleClock.sampleRate.rounded())
        let timescale = CMTimeScale(max(1, roundedSampleRate))
        let startTime = CMTime(value: sampleClock.framePosition, timescale: timescale)
        sampleClock.framePosition += AVAudioFramePosition(nextBuffer.frameLength)
        let endTime = CMTime(value: sampleClock.framePosition, timescale: timescale)
        return PreparedAnalyzerInput(
            input: AnalyzerInput(buffer: nextBuffer),
            outputFrameLength: nextBuffer.frameLength,
            startTime: startTime,
            endTime: endTime
        )
    }

    private static func makeAnalyzerBuffer(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if converter == nil {
            return copyBuffer(buffer)
        }

        guard let converter else {
            return nil
        }

        converter.reset()

        let outputCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil else {
            return nil
        }

        guard convertedBuffer.frameLength > 0 else {
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return convertedBuffer
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        output.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in 0..<sourceBuffers.count {
            guard let sourcePointer = sourceBuffers[index].mData,
                  let destinationPointer = destinationBuffers[index].mData else {
                return nil
            }

            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationPointer, sourcePointer, byteCount)
        }

        return output
    }

    private static func audioMetrics(for buffer: AVAudioPCMBuffer) -> (averagePowerDB: Double, peak: Double)? {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )

        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0

        func accumulate(_ sample: Double) {
            let magnitude = abs(sample)
            sumSquares += sample * sample
            peak = max(peak, magnitude)
            sampleCount += 1
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    accumulate(Double(samples[index]))
                }
            }
        case .pcmFormatFloat64:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let samples = data.bindMemory(to: Double.self, capacity: count)
                for index in 0..<count {
                    accumulate(samples[index])
                }
            }
        case .pcmFormatInt16:
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else {
                    continue
                }

                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    accumulate(Double(samples[index]) / Double(Int16.max))
                }
            }
        default:
            return nil
        }

        guard sampleCount > 0 else {
            return nil
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let averagePowerDB = 20 * log10(max(rms, 0.000_000_1))
        return (averagePowerDB, peak)
    }

    private static func preview(_ text: String, limit: Int = 80) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: "\\n")
        guard cleaned.count > limit else {
            return cleaned.isEmpty ? "<empty>" : cleaned
        }

        return String(cleaned.prefix(limit)) + "..."
    }

    private static func describe(format: AVAudioFormat) -> String {
        "rate=\(format.sampleRate) channels=\(format.channelCount) common=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)"
    }

    private static func describe(time: CMTime) -> String {
        if time.isValid {
            return format(CMTimeGetSeconds(time)) + "s"
        }
        return "invalid"
    }

    private static func describe(optionalTime: CMTime?) -> String {
        guard let optionalTime else {
            return "nil"
        }
        return describe(time: optionalTime)
    }

    private static func describe(diagnostics: CaptureDiagnostics?) -> String {
        guard let diagnostics else {
            return "buffers=0 results=0"
        }

        return "buffers=\(diagnostics.bufferCount) totalFrames=\(diagnostics.totalFrames) totalOutputFrames=\(diagnostics.totalOutputFrames) outputFrames=\(diagnostics.lastOutputFrameLength) results=\(diagnostics.resultCount) lastInputEnd=\(describe(time: diagnostics.lastInputEndTime)) lastAvgPowerDB=\(format(diagnostics.lastAveragePowerDB)) lastPeak=\(format(diagnostics.lastPeak))"
    }

    private static func preferredFinalizeTime(reported: CMTime?, expected: CMTime?) -> CMTime? {
        switch (reported, expected) {
        case let (reported?, expected?):
            return CMTimeCompare(expected, reported) == 1 ? expected : reported
        case let (reported?, nil):
            return reported
        case let (nil, expected?):
            return expected
        case (nil, nil):
            return nil
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpeechTranscriptionError.timedOut(stage: stage)
            }

            guard let result = try await group.next() else {
                throw SpeechTranscriptionError.timedOut(stage: stage)
            }
            group.cancelAll()
            return result
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private nonisolated static func debugPrint(sessionID: String, _ message: String) {
        print("[Speech][\(sessionID)] \(message)")
    }

    private nonisolated static func scheduleBackgroundCleanup(_ cleanup: BackgroundCleanupContext) {
        Task.detached(priority: .utility) {
            if let analyzer = cleanup.analyzer {
                await analyzer.cancelAndFinishNow()
            }

            Self.debugPrint(
                sessionID: cleanup.sessionID,
                "background cleanup finished reason=\(cleanup.reason)"
            )
        }
    }
}
