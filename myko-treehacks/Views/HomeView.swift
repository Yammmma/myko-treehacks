//
//  HomeView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//
import SwiftUI
import UIKit
import ImageIO

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    private let favoriteCardWidth: CGFloat = 210

    private var favoriteItems: [HistoryItem] {
        appState.historyStore.items
            .filter(\.isFavorite)
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString > $1.id.uuidString
                }
                return $0.createdAt > $1.createdAt
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heroSection

                        NavigationLink {
                            CameraScreenView()
                        } label: {
                            Text("Scan Slide")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 56) // ⭐ better standard height
                                .background(MykoColors.leafBase)
                                .foregroundStyle(.white)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .shadow(
                                    color: MykoColors.leafBase.opacity(0.28),
                                    radius: 10,
                                    x: 0,
                                    y: 6
                                )
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Favorites")
                                    .font(.title3.weight(.semibold))

                                Spacer()

                                NavigationLink("See all") {
                                    HistoryView()
                                }
                                .font(.subheadline)
                                .foregroundStyle(MykoColors.leafBase)
                            }

                            favoritesCarousel
                        }

                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Home")
        }
    }

    private var heroSection: some View {
        ZStack {
            TapBounceLogo()
                .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var favoritesCarousel: some View {
        FavoritesCarouselView(items: favoriteItems, cardWidth: favoriteCardWidth)
            .environmentObject(appState)
    }
}

private struct FavoritesCarouselView: View {
    @EnvironmentObject private var appState: AppState
    let items: [HistoryItem]
    let cardWidth: CGFloat

    init(items: [HistoryItem], cardWidth: CGFloat = 210) {
        self.items = items
        self.cardWidth = cardWidth
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Favorites Yet",
                    systemImage: "star",
                    description: Text("Mark items as favorites in History to see them here.")
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(items) { item in
                            FavoriteHistoryCard(item: item, cardWidth: cardWidth)
                                .environmentObject(appState)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

private struct FavoriteHistoryCard: View {
    @State private var thumbnail: UIImage?
    @EnvironmentObject private var appState: AppState
    let item: HistoryItem
    let cardWidth: CGFloat

    init(item: HistoryItem, cardWidth: CGFloat = 210) {
        self.item = item
        self.cardWidth = cardWidth
    }

    var body: some View {
        NavigationLink {
            HistoryDetailView(item: item)
        } label: {
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
                        appState.historyStore.toggleFavorite(for: item)
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(item.isFavorite ? .yellow : .white)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: cardWidth, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                )
        }
        .buttonStyle(.plain)
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

private struct TapBounceLogo: View {
    @State private var pressed = false

    var body: some View {
        Image("myko-logo-transparent")
            .resizable()
            .scaledToFit()
            .frame(height: 240)
            .scaleEffect(pressed ? 1.06 : 1.0)
            .offset(y: pressed ? -6 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pressed)
            .onTapGesture {
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    pressed = false
                }
            }
    }
}


#Preview {
    HomeView()
        .environmentObject(AppState())
}
