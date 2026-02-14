//
//  HomeView.swift
//  myko-treehacks
//
//  Created by Amy Sun Key on 2/13/26.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Home")
                    .font(.title)
                
                NavigationLink("Go to Content") {
                    ContentView()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Home")
        }
        
    }
    //.navigationTitle("Home")
}

#Preview {
    HomeView()
}
