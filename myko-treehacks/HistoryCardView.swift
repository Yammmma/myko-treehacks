//
//  HistoryCardView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/14/26.
//


import SwiftUI
import ImageIO

struct HistoryCardView: View {
    @EnvironmentObject private var appState: AppState
    let item: HistoryItem
    var onFavoriteTap: (() -> Void)? = nil

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(0.9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    } else {
                        ZStack {
                            Color.gray.opacity(0.12)
                            ProgressView()
                        }
                    }
                }

                Button {
                    onFavoriteTap?()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .white)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        )
        .task {
            if thumbnail == nil {
                thumbnail = downsampledImage(at: appState.historyStore.imageURL(for: item), maxDimension: 500)
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
