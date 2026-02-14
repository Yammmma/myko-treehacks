//
//  SpeechAnalyzerTranscriptionService.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechAnalyzerTranscriptionService: ObservableObject {
    enum TranscriptionError: LocalizedError {
        case localeNotSupported
        case permissionDenied
        case setupFailed
        case invalidAudioDataType

        var errorDescription: String? {
            switch self {
            case .localeNotSupported:
                return "Speech transcription is not supported for the selected locale."
            case .permissionDenied:
                return "Microphone or speech recognition permission was denied."
            case .setupFailed:
                return "Failed to set up speech transcription."
            case .invalidAudioDataType:
                return "Invalid audio format for SpeechAnalyzer."
            }
        }
    }

    @Published private(set) var isRecording = false

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?

    private let audioEngine = AVAudioEngine()
    private var recognizerTask: Task<Void, Never>?

    private var finalizedTranscript = ""
    private var volatileTranscript = ""

    func startRecording(locale: Locale = .current, onTranscriptUpdate: @escaping (String) -> Void) async throws {
        guard !isRecording else { return }
        guard await isAuthorized() else { throw TranscriptionError.permissionDenied }

        try setUpAudioSession()
        try await setUpTranscriber(locale: locale)
        startRecognitionTask(onTranscriptUpdate: onTranscriptUpdate)
        try startAudioEngineTap()

        isRecording = true
    }

    func stopRecording() async {
        guard isRecording else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputBuilder?.finish()

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        recognizerTask?.cancel()

        isRecording = false
    }

    private func setUpTranscriber(locale: Locale) async throws {
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        guard let transcriber else { throw TranscriptionError.setupFailed }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        try await ensureModel(transcriber: transcriber, locale: locale)

        (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        guard let inputSequence else { throw TranscriptionError.setupFailed }

        try await analyzer.start(inputSequence: inputSequence)

        finalizedTranscript = ""
        volatileTranscript = ""
    }

    private func startRecognitionTask(onTranscriptUpdate: @escaping (String) -> Void) {
        recognizerTask = Task {
            guard let transcriber else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalizedTranscript += text
                        volatileTranscript = ""
                    } else {
                        volatileTranscript = text
                    }
                    onTranscriptUpdate(finalizedTranscript + volatileTranscript)
                }
            } catch {
                // Task cancellation and stream shutdown are expected when stopping.
            }
        }
    }

    private func startAudioEngineTap() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task {
                try? await self.streamAudioToTranscriber(buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func streamAudioToTranscriber(_ buffer: AVAudioPCMBuffer) async throws {
        guard let inputBuilder, let analyzerFormat else {
            throw TranscriptionError.invalidAudioDataType
        }

        let analyzerBuffer = try convertBuffer(buffer, to: analyzerFormat)
        let input = AnalyzerInput(buffer: analyzerBuffer)
        inputBuilder.yield(input)
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if isSameFormat(buffer.format, targetFormat) {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw TranscriptionError.invalidAudioDataType
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw TranscriptionError.invalidAudioDataType
        }

        var conversionError: NSError?
        var providedBuffer = false
        converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if providedBuffer {
                outStatus.pointee = .noDataNow
                return nil
            } else {
                providedBuffer = true
                outStatus.pointee = .haveData
                return buffer
            }
        }

        if let conversionError {
            throw conversionError
        }

        return convertedBuffer
    }

    private func isAuthorized() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            let micAllowed: Bool
            if audioSession.recordPermission == .undetermined {
                micAllowed = await withCheckedContinuation { continuation in
                    audioSession.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                micAllowed = audioSession.recordPermission == .granted
            }
            return status == .authorized && micAllowed
        #else
            return status == .authorized
        #endif
    }

    private func isSameFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.channelCount == rhs.channelCount
            && abs(lhs.sampleRate - rhs.sampleRate) < 0.01
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw TranscriptionError.localeNotSupported
        }

        if await installed(locale: locale) {
            return
        }

        try await downloadIfNeeded(for: transcriber)
    }

    private func supported(locale: Locale) async -> Bool {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        return supportedLocales
            .map { $0.identifier(.bcp47) }
            .contains(locale.identifier(.bcp47))
    }

    private func installed(locale: Locale) async -> Bool {
        let installedLocales = await Set(SpeechTranscriber.installedLocales)
        return installedLocales
            .map { $0.identifier(.bcp47) }
            .contains(locale.identifier(.bcp47))
    }

    private func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }

    #if os(iOS)
        private func setUpAudioSession() throws {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }
    #else
        private func setUpAudioSession() throws {}
    #endif
}
