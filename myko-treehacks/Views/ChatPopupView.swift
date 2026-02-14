//
//  ChatPopupView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//


import SwiftUI

struct ChatPopupView: View {
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Myko")
                    .font(.headline)

                Spacer()

                if !chat.messages.isEmpty {
                    Button("Clear") {
                        chat.clear()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            Text("Ask Myko anything about what you're seeing.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 22)
                        } else {
                            ForEach(chat.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = chat.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 30) }

            Text(message.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isUser ? MykoColors.coralBase : Color.white.opacity(0.6))
                )

            if !isUser { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity)
    }
}