//
//  AppState.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case home
        case history
    }
    
    enum HistorySortMode: Hashable {
        case newest
        case favorites
    }

    @Published var selectedTab: Tab = .home
    @Published var historySortMode: HistorySortMode = .newest

    let historyStore = HistoryStore()
    private var cancellables = Set<AnyCancellable>()

    init() {
        historyStore.objectWillChange
            .sink { _ in
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }
}
