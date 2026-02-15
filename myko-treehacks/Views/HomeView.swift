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
                .background(Color.white)
                .navigationTitle("Home")
            }
        }

        private var heroSection: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.systemGray6)) // or your brand color

                TapBounceLogo()
                    .frame(maxHeight: 260)
                
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)


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

            VStack(alignment: .leading, spacing: 4) {

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)
        }
        .frame(width: 280, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
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
