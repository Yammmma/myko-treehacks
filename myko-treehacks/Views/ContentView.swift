//
//  ContentView.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isChatExpanded = false
    @State private var chatMessage = ""
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
        .navigationTitle("Content")
        .toolbar {
            
            ToolbarItem(placement: .bottomBar) {
                ToolbarView(
                    isEditing: false,
                    onChat: { isChatExpanded.toggle() },
                    onSendMessage: {
                        // send message
                        print("send:", chatMessage)
                        chatMessage = ""
                    },
                    isChatExpanded: $isChatExpanded,
                    chatMessage: $chatMessage
                )
            }
        }
    }
    
}

struct ToolbarView: View {
    let isEditing: Bool
    let onChat: () -> Void
    let onSendMessage: () -> Void
    @Binding var isChatExpanded: Bool
    @Binding var chatMessage: String
    
    var body: some View {
        HStack(spacing: 12) {
            if isChatExpanded {
                Button(action: onChat) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                
                TextField("Ask Myko…", text: $chatMessage)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                    .submitLabel(.send)
                    .onSubmit { onSendMessage() }
                
                Button(action: onSendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(MykoColors.coralBase))
                }
            } else {
                // collapsed state: just show the chat button (or add more)
                Button(action: onChat) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .animation(.easeInOut(duration: 0.2), value: isChatExpanded)
    }
}

struct ToolbarButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? MykoColors.coralBase : .white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isActive ? MykoColors.coralLight.opacity(0.4) : Color.white.opacity(0.08))
                )
        }
        .accessibilityLabel(title)
    }
}


struct ToastView: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(MykoColors.biologyBase.opacity(0.3), lineWidth: 1))
            .foregroundStyle(.primary)
    }
}

#Preview {
    NavigationStack {
        ContentView()
    }
}
