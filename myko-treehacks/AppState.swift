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

    @Published var selectedTab: Tab = .home
}
