//
//  HistoryView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    private enum SortMode: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case favorites = "Favorites"

        var id: String { rawValue }
    }

    @State private var sortMode: SortMode = .newest

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var sortedItems: [HistoryItem] {
        let items = appState.historyStore.items
        switch sortMode {
        case .newest:
            return items.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString > $1.id.uuidString
                }
                return $0.createdAt > $1.createdAt
            }
        case .favorites:
            return items.sorted {
                if $0.isFavorite != $1.isFavorite {
                    return $0.isFavorite && !$1.isFavorite
                }
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString > $1.id.uuidString
                }
                return $0.createdAt > $1.createdAt
            }
        }
    }

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
                            ForEach(sortedItems) { item in
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Sort", selection: $sortMode) {
                        ForEach(SortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }
}


private struct HistoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    private let itemID: HistoryItem.ID

    init(item: HistoryItem) {
        self.itemID = item.id
    }

    private var item: HistoryItem? {
        appState.historyStore.items.first(where: { $0.id == itemID })
    }

    var body: some View {
        Group {
            if let item,
               let image = UIImage(contentsOfFile: appState.historyStore.imageURL(for: item).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.9))
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            }
        }
        .navigationTitle(item?.title ?? "Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.historyStore.toggleFavorite(for: item)
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(item.isFavorite ? .yellow : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppState())
}
