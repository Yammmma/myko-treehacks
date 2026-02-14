//
//  ChatMessage.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//


import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case myko
    }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}