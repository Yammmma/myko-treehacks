//
//  CameraView.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import AVFoundation
import UIKit
import CoreImage
import CoreVideo

struct CameraView: View {
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showSettingsAlert = false
    
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    @State private var capturedImage: UIImage?
    @State private var isCapturing = false
//    https://547e-171-66-12-188.ngrok-free.app/query
    var body: some View {
        ZStack {
            switch authorizationStatus {
            case .authorized:
                CameraPreview(currentZoom: $currentZoom, totalZoom: $totalZoom, capturedImage: $capturedImage, isCapturing: $isCapturing)
                      .ignoresSafeArea()
                      .clipShape(Circle())
                      .overlay(alignment: .bottom) {
                          Button(action: { isCapturing = true }) {
                              Image(systemName: "circle.inset.filled")
                                  .font(.system(size: 44))
                                  .foregroundStyle(.white)
                                  .shadow(radius: 4)
                                  .padding(24)
                          }
                      }
                      .overlay {
                          if let image = capturedImage {
                              Image(uiImage: image)
                                  .resizable()
                                  .scaledToFit()
                                  .transition(.opacity)
                          }
                      }
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
    @Binding var capturedImage: UIImage?
    @Binding var isCapturing: Bool
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configureSession(on: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.updateZoom(to: currentZoom + totalZoom)
        if isCapturing {
            context.coordinator.requestSnapshot { image in
                DispatchQueue.main.async {
                    self.capturedImage = image
                    self.isCapturing = false
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "camera.session.queue")
        private var device: AVCaptureDevice?
        private var deviceLockAcquired = false
        
        private let videoOutput = AVCaptureVideoDataOutput()
        private let outputQueue = DispatchQueue(label: "camera.video.output.queue")
        private let ciContext = CIContext()
        private var pendingSnapshotRequest: ((UIImage?) -> Void)?

        func configureSession(on previewView: PreviewView) {
            previewView.videoPreviewLayer.session = session
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high

                // Input: Rear wide angle camera
                guard let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
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

                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
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
        }
        
        func requestSnapshot(completion: @escaping (UIImage?) -> Void) {
            // Keep only the last requester
            pendingSnapshotRequest = completion
        }
        
        private func cgImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }
        
        private func circularMaskedImage(from cgImage: CGImage) -> CGImage? {
            let width = cgImage.width
            let height = cgImage.height
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = 0
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.setShouldAntialias(true)

            let radius = CGFloat(min(width, height)) / 2.0
            let center = CGPoint(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.addEllipse(in: rect)
            context.clip()

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let requester = pendingSnapshotRequest else { return }
            pendingSnapshotRequest = nil

            guard let cg = cgImage(from: sampleBuffer),
                  let masked = circularMaskedImage(from: cg) else {
                requester(nil)
                return
            }
            let uiImage = UIImage(cgImage: masked)
            requester(uiImage)
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
        videoPreviewLayer.videoGravity = .resizeAspect
    }
}

#Preview {
    CameraView()
}
