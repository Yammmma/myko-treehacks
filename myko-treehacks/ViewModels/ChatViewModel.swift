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
    private var liveDictationMessageID: UUID?
    
    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        send(trimmed)
        draft = ""
    }
    
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        liveDictationMessageID = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        isSending = true
        sendMessage.send(trimmed)
    }
    
    func updateLiveDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            if let liveDictationMessageID,
               let index = messages.firstIndex(where: { $0.id == liveDictationMessageID }) {
                messages.remove(at: index)
            }
            liveDictationMessageID = nil
            return
        }
        
        if let liveDictationMessageID,
           let index = messages.firstIndex(where: { $0.id == liveDictationMessageID }) {
            let previous = messages[index]
            messages[index] = ChatMessage(
                id: previous.id,
                role: previous.role,
                text: trimmed,
                timestamp: previous.timestamp
            )
            return
        }
        
        let message = ChatMessage(role: .user, text: trimmed)
        liveDictationMessageID = message.id
        messages.append(message)
    }
    
    func clear() {
        messages.removeAll()
        liveDictationMessageID = nil
    }
    
    func receivedMessage(_ message: String) {
        messages.append(ChatMessage(role: .myko, text: message))
        isSending = false
    }
}
