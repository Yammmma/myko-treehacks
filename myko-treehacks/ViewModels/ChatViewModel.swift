//
//  ChatViewModel.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import Combine
import Foundation

let sendMessage = PassthroughSubject<String, Never>()
let receiveMessage = PassthroughSubject<String, Never>()

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
        sendMessage.send(trimmed)
    }

    func clear() {
        messages.removeAll()
    }
    
    func receivedMessage(_ message: String) {
        messages.append(ChatMessage(role: .myko, text: message))
        isSending = false
    }
}
