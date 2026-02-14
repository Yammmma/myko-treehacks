//
//  myko_treehacksApp.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI

@main
struct myko_treehacksApp: App {
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    var body: some Scene {
        WindowGroup {
//            ContentView()
            CameraView()
        }
    }
}
