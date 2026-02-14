//
//  HistoryView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if appState.historyStore.items.isEmpty {
                    ContentUnavailableView(
                        "No Captures Yet",
                        systemImage: "camera.metering.none",
                        description: Text("Take a screenshot from the camera tab to populate History.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(appState.historyStore.items) { item in
                                NavigationLink {
                                    HistoryDetailView(item: item)
                                        .environmentObject(appState)
                                } label: {
                                    HistoryCardView(item: item)
                                        .environmentObject(appState)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}


private struct HistoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    let item: HistoryItem

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: appState.historyStore.imageURL(for: item).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.9))
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppState())
}
