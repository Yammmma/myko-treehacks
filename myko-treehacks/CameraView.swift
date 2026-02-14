//
//  CameraView.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showSettingsAlert = false
    
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0

    var body: some View {
        Group {
            switch authorizationStatus {
            case .authorized:
                CameraPreview(currentZoom: $currentZoom, totalZoom: $totalZoom)
                    .ignoresSafeArea()
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
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    currentZoom = value.magnification - 1
                }
                .onEnded { value in
                    totalZoom += currentZoom
                    currentZoom = 0
                }
        )
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

// MARK: - Camera Preview Wrapper

private struct CameraPreview: UIViewRepresentable {
    @Binding var currentZoom: Double
    @Binding var totalZoom: Double
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configureSession(on: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
//        uiView.videoPreviewLayer.contentsScale = currentZoom + totalZoom
        context.coordinator.updateZoom(to: currentZoom + totalZoom)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "camera.session.queue")
        private var device: AVCaptureDevice?
        private var deviceLockAcquired = false

        func configureSession(on previewView: PreviewView) {
            previewView.videoPreviewLayer.session = session
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high

                // Input: Rear wide angle camera
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)
                self.device = device
                
                do {
                    try device.lockForConfiguration()
                    deviceLockAcquired = true
                } catch {
                    print("Can't acquire camera lock", error)
                }

                // TODO: Add output feed for inferencing

                self.session.commitConfiguration()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
        
        func updateZoom(to zoom: Double) {
            let clampedZoom = min(max(zoom, 1), device?.activeFormat.videoMaxZoomFactor ?? 1)
            
            device?.videoZoomFactor = clampedZoom
//            previewView.videoPreviewLayer.contentsScale = zoom
        }

        deinit {
            if deviceLockAcquired {
                device?.unlockForConfiguration()
            }
            
            if session.isRunning { session.stopRunning() }
        }
    }
}

// MARK: - PreviewView (CALayer backed)

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        videoPreviewLayer.videoGravity = .resizeAspectFill
    }
}

#Preview {
    CameraView()
}
