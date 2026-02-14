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

let ENDPOINT_URL_BASE = "547e-171-66-12-188.ngrok-free.app"

struct CameraView: View {
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showSettingsAlert = false
    
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    @State private var capturedImage: UIImage?
    @State private var isCapturing = false
    
    @State private var annotatedImage: UIImage?
    
    var body: some View {
        ZStack {
            switch authorizationStatus {
            case .authorized:
                CameraPreview(currentZoom: $currentZoom, totalZoom: $totalZoom, capturedImage: $capturedImage, annotatedImage: $annotatedImage, isCapturing: $isCapturing)
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
                        if let image = annotatedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
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
    @Binding var annotatedImage: UIImage?
    @Binding var isCapturing: Bool
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configureSession(on: view)
        
        // Start WebSocket connection
        context.coordinator.setupWebSocket()
        
        // Callback to update the SwiftUI binding when a frame arrives
        context.coordinator.onFrameReceived = { image in
            self.annotatedImage = image
        }
        
        // Continuous capture loop (15 FPS)
        Timer.scheduledTimer(withTimeInterval: 1/15, repeats: true) { _ in
            captureImage(context: context)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.updateZoom(to: currentZoom + totalZoom)
        
        // Handle manual capture trigger
        if isCapturing {
            if let img = capturedImage {
                context.coordinator.sendFrame(image: img)
            }
            DispatchQueue.main.async {
                self.isCapturing = false
            }
        }
    }
    
    func captureImage(context: Context) {
        context.coordinator.requestSnapshot { image in
            DispatchQueue.main.async {
                self.capturedImage = image
                // Automatically send frame for real-time tracking
                if let img = image {
                    context.coordinator.sendFrame(image: img)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // MARK: - Coordinator (Handles Camera & WebSocket)
    
    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        // --- Camera Properties ---
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "camera.session.queue")
        private var device: AVCaptureDevice?
        private var deviceLockAcquired = false
        private let videoOutput = AVCaptureVideoDataOutput()
        private let outputQueue = DispatchQueue(label: "camera.video.output.queue")
        private let ciContext = CIContext()
        private var pendingSnapshotRequest: ((UIImage?) -> Void)?
        
        // --- WebSocket Properties ---
        private var webSocketTask: URLSessionWebSocketTask?
        var onFrameReceived: ((UIImage) -> Void)?
        
        struct InferenceWSSchema: Codable {
            let frame: String
        }
        
        // 1. Setup
        func setupWebSocket() {
            guard let url = URL(string: "wss://\(ENDPOINT_URL_BASE)/ws") else {
                print("❌ Invalid URL")
                return
            }
            webSocketTask = URLSession.shared.webSocketTask(with: url)
            webSocketTask?.resume()
            print("⚡ WebSocket Connecting...")
            listenForMessages()
        }
        
        // 2. Recursive Listener (Crucial for Stream)
        private func listenForMessages() {
            webSocketTask?.receive { [weak self] result in
                guard let self = self else { return }
                
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    // RECURSION: Keep listening!
                    self.listenForMessages()
                    
                case .failure(let error):
                    print("❌ WebSocket Receive Error: \(error)")
                    // Optional: logic to reconnect could go here
                }
            }
        }
        
        // 3. Robust Decoding
        private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
            switch message {
            case .string(let imageB64):
                // Sanitize: Remove newlines, whitespace, and quotes
                var sanitized = imageB64.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                
                // Remove 'data:image/jpeg;base64,' prefix if present
                if let commaRange = sanitized.range(of: ",") {
                    sanitized = String(sanitized[commaRange.upperBound...])
                }
                
                if let imageData = Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters),
                   let image = UIImage(data: imageData) {
                    DispatchQueue.main.async { self.onFrameReceived?(image) }
                } else {
                    print("⚠️ Failed to decode Base64 string")
                }
                
            case .data(let data):
                if let image = UIImage(data: data) {
                    DispatchQueue.main.async { self.onFrameReceived?(image) }
                }
            @unknown default:
                break
            }
        }
        
        // 4. Send Frame
        func sendFrame(image: UIImage) {
            guard let frameB64 = image.base64EncodedString() else { return }
            
            // Construct JSON payload
            let schema = InferenceWSSchema(frame: frameB64)
            
            do {
                let jsonData = try JSONEncoder().encode(schema)
                let message = URLSessionWebSocketTask.Message.data(jsonData)
                
                webSocketTask?.send(message) { error in
                    if let error = error {
                        print("❌ Error sending frame: \(error)")
                    }
                }
            } catch {
                print("❌ JSON Encoding Error: \(error)")
            }
        }
        
        // --- Camera Logic ---
        
        func configureSession(on previewView: PreviewView) {
            previewView.videoPreviewLayer.session = session
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                
                let selectedDevice = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                
                guard let device = selectedDevice,
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
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
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
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
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

extension UIImage {
    func base64EncodedString() -> String? {
        guard let imageData = self.jpegData(compressionQuality: 0.5) else { return nil }
        let base64String = imageData.base64EncodedString(options: [])
        // IMPORTANT: Python server expects "data:image..." or just base64 depending on configuration.
        // Based on your last error, it is safer to send the prefix so Agent.py is happy.
        return "data:image/jpeg;base64,\(base64String)"
    }
}

#Preview {
    CameraView()
}
