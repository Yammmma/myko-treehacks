//
//  ChatViewModel.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isChatExpanded = false
    @Published var isSending = false

    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        draft = ""
        isSending = true

        Task {
            try? await Task.sleep(for: .milliseconds(350))
            messages.append(ChatMessage(role: .myko, text: stubReply(for: trimmed)))
            isSending = false
        }
    }

    func clear() {
        messages.removeAll()
    }

    private func stubReply(for prompt: String) -> String {
        "I heard you say: \(prompt). I can help analyze this sample next."
    }
}
