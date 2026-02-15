//
//  HomeView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

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
                            CameraView()
                        } label: {
                            Text("Start Scan")
                                .font(.title2.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
                                .background(MykoColors.leafBase)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Favorites")
                                .font(.title2.weight(.semibold))

                            favoritesCarousel
                        }

                        NavigationLink("Go to Content") {
                            ContentView()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Home")
            }
        }
    private var heroSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [ Color.white, MykoColors.leafLight.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(MykoColors.leafBase.opacity(0.15), lineWidth: 1)
                )

            Image("myko-logo-transparent")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 8)
    }

    private var favoritesCarousel: some View {
        Group {
            if favoriteItems.isEmpty {
                ContentUnavailableView(
                    "No Favorites Yet",
                    systemImage: "star",
                    description: Text("Mark items as favorites in History to see them here.")
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(favoriteItems) { item in
                            FavoriteCardView(item: item)
                                .environmentObject(appState)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 2)
                }
                .contentMargins(.horizontal, 2)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }
}

private struct FavoriteCardView: View {
    @EnvironmentObject private var appState: AppState
    let item: HistoryItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = UIImage(contentsOfFile: appState.historyStore.imageURL(for: item).path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [MykoColors.leafLight, MykoColors.leafBase.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(16)
        }
        .frame(width: 280, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 6)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
