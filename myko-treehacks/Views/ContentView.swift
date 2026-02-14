//
//  ContentView.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var chat = ChatViewModel()
    @StateObject private var transcriptionService = SpeechAnalyzerTranscriptionService()

    @State private var transcriptionError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraView()

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
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: chat.isChatExpanded)
        .safeAreaInset(edge: .bottom) {
            if chat.isChatExpanded {
                ChatComposerBar(
                    chat: chat,
                    isRecording: transcriptionService.isRecording,
                    onToggleRecording: {
                        Task { await toggleRecording() }
                    },
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
                        // TODO: hook up editing box toggle later
                    } label: {
                        Image(systemName: "crop") // later: swap based on editing state
                    }
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
                        // TODO: hook up capture action later
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
        .toolbar(.hidden, for: .tabBar)
        .alert("Transcription Failed", isPresented: .constant(transcriptionError != nil), actions: {
            Button("OK") { transcriptionError = nil }
        }, message: {
            Text(transcriptionError ?? "Unknown error")
        })
    }

    @MainActor
    private func toggleRecording() async {
        if transcriptionService.isRecording {
            await transcriptionService.stopRecording()
            return
        }

        do {
            try await transcriptionService.startRecording { transcript in
                Task { @MainActor in
                    chat.draft = transcript
                }
            }
        } catch {
            transcriptionError = error.localizedDescription
        }
    }
}

private struct ChatComposerBar: View {
    @ObservedObject var chat: ChatViewModel
    let isRecording: Bool
    let onToggleRecording: () -> Void
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

            Button(action: onToggleRecording) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .red : MykoColors.biologyBase)
            .accessibilityLabel("Dictate message")

            Button {
                chat.send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
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
