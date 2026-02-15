//
//    CameraView.swift
//    myko-treehacks
//
//    Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import UIKit
import Combine
import AVFoundation

struct CameraView: View {
    @ObservedObject var endpoint: EndpointViewModel
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    
    private var actualZoom: Double { currentZoom + totalZoom }
    
    var body: some View {
        ZStack {
            switch authorizationStatus {
            case .authorized:
                VStack {
                    Spacer()
                    
                    if let capturedImage = endpoint.capturedImage {
                        Image(uiImage: endpoint.annotatedImage ?? capturedImage)
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .padding()
                    }
                    
                    Spacer()
                }
                .padding()
            case .notDetermined:
                VStack(spacing: 16) {
                    Text("Camera Access Required")
                        .font(.headline)
                    Text("We need access to your camera to show a live preview.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Allow Camera Access") {
                        requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .onAppear {
                    requestAccess()
                }
            case .denied, .restricted:
                VStack(spacing: 16) {
                    Text("Camera Access Denied")
                        .font(.headline)
                    Text("Please enable camera access in Settings to use this feature.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        openSettings()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            @unknown default:
                Text("Unsupported authorization status")
            }
        }
        .onAppear {
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    currentZoom = value.magnification - 1
                    endpoint.updateZoom(to: actualZoom)
                }
                .onEnded { value in
                    totalZoom += currentZoom
                    currentZoom = 0
                    endpoint.updateZoom(to: actualZoom)
                }
        )
        .onReceive(sendMessage) { message in
            endpoint.captureImage(mode: .query, prompt: message)
        }
    }
    
    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.authorizationStatus = granted ? .authorized : .denied
            }
        }
    }
    
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    CameraView(endpoint: EndpointViewModel())
}
