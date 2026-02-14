//
//  HandsFreeModeController.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/14/26.
//


import AudioToolbox
import Foundation
import Combine

@MainActor
final class HandsFreeModeController: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var isArmed = false
    @Published private(set) var isCapturingCommand = false
    @Published private(set) var statusText = "Hands-Free Off"

    private let wakePhrase = "hey myko"
    private let silenceTimeout: TimeInterval = 1.4

    private var service = SpeechAnalyzerTranscriptionService()
    private var silenceTask: Task<Void, Never>?
    private var commandBuffer = ""
    private var onCommandUpdate: ((String) -> Void)?
    private var executeCommand: ((String) -> Void)?

    func updateMode(
        enabled: Bool,
        appIsForegrounded: Bool,
        onCommandUpdate: @escaping (String) -> Void,
        onExecute: @escaping (String) -> Void
    ) {
        self.onCommandUpdate = onCommandUpdate
        executeCommand = onExecute

        guard enabled != isEnabled || (!enabled && (isArmed || isCapturingCommand)) else {
            if enabled && appIsForegrounded && !isArmed && !isCapturingCommand {
                Task { await armWakeListening() }
            }
            return
        }

        isEnabled = enabled

        if enabled, appIsForegrounded {
            Task { await armWakeListening() }
        } else {
            Task { await stopAllListening() }
        }
    }

    func updateForegroundState(isForegrounded: Bool) {
        guard isEnabled else { return }

        if isForegrounded {
            Task { await armWakeListening() }
        } else {
            Task { await stopAllListening() }
        }
    }

    func stopAllListening() async {
        silenceTask?.cancel()
        silenceTask = nil
        commandBuffer = ""
        onCommandUpdate?("")

        if service.isRecording {
            await service.stopRecording()
        }

        isArmed = false
        isCapturingCommand = false
        statusText = isEnabled ? "Paused (Background)" : "Hands-Free Off"
    }

    private func armWakeListening() async {
        guard isEnabled, !service.isRecording, !isCapturingCommand else { return }

        do {
            statusText = "🎙️ Listening for \"Hey Myko\""
            try await service.startRecording { [weak self] transcript in
                guard let self else { return }
                self.processWakeTranscript(transcript)
            }
            isArmed = true
        } catch {
            statusText = "Hands-Free unavailable: \(error.localizedDescription)"
            isEnabled = false
            isArmed = false
        }
    }

    private func processWakeTranscript(_ transcript: String) {
        let normalized = transcript.lowercased()
        guard let range = normalized.range(of: wakePhrase) else { return }

        let suffix = String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("[HandsFree] Wake phrase heard: \(wakePhrase). Transcript: \(transcript)")

        Task {
            await service.stopRecording()
            isArmed = false
            playWakeChime()
            await startCommandCapture(initialText: suffix)
        }
    }

    private func startCommandCapture(initialText: String) async {
        guard isEnabled else { return }

        commandBuffer = initialText
        isCapturingCommand = true
        statusText = "Listening for command…"
        onCommandUpdate?(commandBuffer)

        do {
            try await service.startRecording { [weak self] transcript in
                guard let self else { return }
                self.commandBuffer = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onCommandUpdate?(self.commandBuffer)
                self.restartSilenceTimer()
            }

            if !initialText.isEmpty {
                restartSilenceTimer()
            }
        } catch {
            statusText = "Command capture failed"
            isCapturingCommand = false
            await armWakeListening()
        }
    }

    private func restartSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(silenceTimeout))
            guard let self else { return }
            await self.finishCommandCapture()
        }
    }

    private func finishCommandCapture() async {
        guard isCapturingCommand else { return }

        silenceTask?.cancel()
        silenceTask = nil

        await service.stopRecording()
        isCapturingCommand = false

        let command = commandBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        commandBuffer = ""

        if !command.isEmpty {
            statusText = "Executing: \"\(command)\""
            executeCommand?(command)
        } else {
            onCommandUpdate?("")
        }

        await armWakeListening()
    }

    private func playWakeChime() {
        AudioServicesPlaySystemSound(1113)
    }
}
