//
//  ContentView.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import UIKit
import Combine

private struct NotesInferenceRequest: Codable {
    let prompt: String
    let frame: String
}

private struct NotesInferenceResponse: Codable {
    let response: String
}

private let screenshotNotesPrompt = """
You are generating notes for a saved microscope screenshot in the Myko camera view.
Write 1–2 concise, confident sentences describing the tissue and cell morphology that are visible.
Use technical pathology language, avoid hedging, and do not ask for additional input.
"""

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @StateObject private var chat = ChatViewModel()
    @StateObject private var endpoint = EndpointViewModel()
//    @StateObject private var transcriptionService = SpeechAnalyzerTranscriptionService()
    @StateObject private var handsFreeController = HandsFreeModeController()
    
//    @State private var transcriptionError: String?
    @State private var captureError: String?
    @State private var showSavedToast = false
    @State private var handsFreeEnabled = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            CameraView(endpoint: endpoint)
            VStack(spacing: 12) {
                Spacer()
                
                if !chat.isChatExpanded, !chat.messages.isEmpty {
                    CollapsedChatPill(chat: chat) {
                        withAnimation(.spring()) {
                            chat.isChatExpanded = true
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 20)
                }
                
                if chat.isChatExpanded {
                    ChatPopupView(chat: chat)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
            if showSavedToast {
                Text("Saved to History")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
                    .padding(.bottom, chat.isChatExpanded ? 88 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack {
                HStack {
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 6) {
                        Toggle("Hands-Free Mode", isOn: $handsFreeEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: handsFreeEnabled) { _, enabled in
                                handsFreeController.updateMode(
                                    enabled: enabled,
                                    appIsForegrounded: scenePhase == .active,
                                    onCommandUpdate: updateHandsFreeDraft,
                                    onExecute: runHandsFreeCommand
                                )
                            }
                        
                        Text(handsFreeController.statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                Spacer()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: chat.isChatExpanded)
        .safeAreaInset(edge: .bottom) {
            if chat.isChatExpanded {
                ChatComposerBar(
                    chat: chat,
//                    isRecording: transcriptionService.isRecording,
//                    onToggleRecording: {
//                        Task { await toggleRecording() }
//                    },
                    onClose: {
                        withAnimation(.spring()) {
                            chat.isChatExpanded = false
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            if !chat.isChatExpanded {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        endpoint.toggleBoundingBoxLock()
                    } label: {
                        Image(systemName: "crop")
                    }
                    .accessibilityLabel(endpoint.isBoundingBoxLocked ? "Unlock bounding box" : "Lock bounding box")
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        // TODO: hook up analysis action later
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        endpoint.captureImage(mode: .manualCapture)
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Spacer().frame(width: 12)
                }
                
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        withAnimation(.spring()) {
                            chat.isChatExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "message.fill")
                    }
                    .accessibilityLabel("Open chat")
                }
                
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.visible, for: .bottomBar)
        //        .alert("Transcription Failed", isPresented: .constant(transcriptionError != nil), actions: {
//            Button("OK") { transcriptionError = nil }
//        }, message: {
//            Text(transcriptionError ?? "Unknown error")
//        })
        .alert("Save Failed", isPresented: .constant(captureError != nil), actions: {
            Button("OK") { captureError = nil }
        }, message: {
            Text(captureError ?? "Unknown error")
        })
        
        .onReceive(receiveMessage) { message in
            chat.receivedMessage(message)
        }
        .onAppear {
            endpoint.onCapture = handleCapturedImage
        }
        .onChange(of: scenePhase) { _, phase in
            handsFreeController.updateForegroundState(isForegrounded: phase == .active)
        }
        
    }
    @MainActor
    private func handleCapturedImage(_ image: UIImage) {
        do {
            let savedItem = try appState.historyStore.save(image: image)
            showSavedToast = true
            captureError = nil

            Task {
                let generatedNotes = await generateNotes(for: image)
                guard let generatedNotes else { return }

                await MainActor.run {
                    appState.historyStore.updateNotes(for: savedItem.id, notes: generatedNotes)
                }
            }
            
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                showSavedToast = false
            }
            
            // Debug photo capture
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        } catch {
            captureError = "Couldn't save screenshot to History."
        }
    }
    
    private func generateNotes(for image: UIImage) async -> String? {
        guard let url = URL(string: "https://\(ENDPOINT_URL_BASE)/query") else { return nil }
        guard let frameB64 = image.base64EncodedString() else { return nil }

        let requestPayload = NotesInferenceRequest(
            prompt: screenshotNotesPrompt,
            frame: frameB64
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(requestPayload)
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(NotesInferenceResponse.self, from: data)
            let trimmed = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(200))
        } catch {
            return nil
        }
    }
    
//    @MainActor
//    private func toggleRecording() async {
//        if handsFreeEnabled {
//            handsFreeEnabled = false
//            await handsFreeController.stopAllListening()
//        }
//        if transcriptionService.isRecording {
//            await transcriptionService.stopRecording()
//            return
//        }
        
//        do {
//            try await transcriptionService.startRecording { transcript in
//                Task { @MainActor in
//                    chat.draft = transcript
//                }
//            }
//        } catch {
//            transcriptionError = error.localizedDescription
//        }
//    }
    
    @MainActor
    private func updateHandsFreeDraft(_ transcript: String) {
        withAnimation(.spring()) {
            chat.isChatExpanded = true
        }
        
        chat.updateLiveDictation(transcript)
    }
    
    
    @MainActor
    private func runHandsFreeCommand(_ command: String) {
        withAnimation(.spring()) {
            chat.isChatExpanded = true
        }
        
        chat.send(command)
    }
}

struct CameraScreenView: View {
    var body: some View {
        ContentView()
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
    }
}

private struct ChatComposerBar: View {
    @ObservedObject var chat: ChatViewModel
//    let isRecording: Bool
//    let onToggleRecording: () -> Void
    let onClose: () -> Void
    
    @FocusState private var isFocused: Bool
    
    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(MykoColors.blush)
            .buttonStyle(.bordered)
            .accessibilityLabel("Close chat")
            
            TextField("Ask Myko…", text: $chat.draft, axis: .vertical)
                .focused($isFocused)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(Color.clear)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit {
                    chat.send()
                }
            
//            Button(action: onToggleRecording) {
//                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
//                    .font(.system(size: 15, weight: .semibold))
//            }
//            .buttonStyle(.bordered)
//            .tint(isRecording ? .red : MykoColors.leafBase)
//            .accessibilityLabel("Dictate message")
            
            Button {
                chat.send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(MykoColors.leafBase)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .onAppear { isFocused = true }
    }
}

private struct CollapsedChatPill: View {
    @ObservedObject var chat: ChatViewModel
    let onTap: () -> Void
    
    private var snippet: String {
        chat.messages.last?.text ?? ""
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text("Myko")
                    .font(.subheadline.weight(.semibold))
                Text(snippet)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
}
