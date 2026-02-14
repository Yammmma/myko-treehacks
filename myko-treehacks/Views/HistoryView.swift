//
//  HistoryView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import SwiftUI
import ImageIO

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
                                    HistoryThumbnailView(item: item)
                                        .environmentObject(appState)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct HistoryThumbnailView: View {
    @EnvironmentObject private var appState: AppState
    let item: HistoryItem

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.gray.opacity(0.15)
                        ProgressView()
                    }
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task {
            if thumbnail == nil {
                thumbnail = downsampledImage(at: appState.historyStore.imageURL(for: item), maxDimension: 400)
            }
        }
    }

    private func downsampledImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
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
        .navigationTitle(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppState())
}
