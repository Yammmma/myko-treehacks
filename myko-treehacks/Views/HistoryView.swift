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
    @State private var selectedItem: HistoryItem?

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
            return items
                .filter { $0.isFavorite }
                .sorted {
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
                                HistoryCardView(item: item) {
                                    appState.historyStore.toggleFavorite(for: item)
                                }
                                .environmentObject(appState)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedItem = item
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(item: $selectedItem) { item in
                HistoryDetailView(item: item)
                    .environmentObject(appState)
            }
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


struct HistoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    private let itemID: HistoryItem.ID
    @State private var draftNotes: String = ""

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
                ScrollView {
                    VStack(spacing: 16) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(0.9)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.horizontal, 10)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notes")
                                .font(.headline)

                            TextEditor(text: $draftNotes)
                                .frame(minHeight: 120)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .scrollContentBackground(.hidden)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white)
                                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)                                )
                                .onChange(of: draftNotes) { _, updatedValue in
                                    appState.historyStore.updateNotes(for: item.id, notes: updatedValue)
                                }
                        }
                        .padding(10)
                        .padding(.horizontal, 4)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            }
        }
        .onAppear {
            draftNotes = item?.notes ?? ""
        }
        .onChange(of: item?.notes ?? "") { _, currentNotes in
            if currentNotes != draftNotes {
                draftNotes = currentNotes
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
