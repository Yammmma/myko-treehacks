//
//  myko_treehacksApp.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import SwiftData

@main
struct myko_treehacksApp: App {
    @StateObject private var appState = AppState()
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        .modelContainer(sharedModelContainer)
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isOnboardingPresented = true
    
    var body: some View {
        TabView(selection: $appState.selectedTab) {
            
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppState.Tab.home)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(AppState.Tab.history)

        }
        .tint(MykoColors.leafBase)
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView(isPresented: $isOnboardingPresented)
        }
    }
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}
