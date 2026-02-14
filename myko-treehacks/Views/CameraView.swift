//
//    CameraView.swift
//    myko-treehacks
//
//    Created by Yuma Soerianto on 2/13/26.
//

import SwiftUI
import AVFoundation
import UIKit
import CoreImage
import CoreVideo
import Combine

// Ensure this matches your ngrok URL exactly
let ENDPOINT_URL_BASE = "547e-171-66-12-188.ngrok-free.app"

struct CameraView: View {
    var captureTrigger: Int = 0
    var onCapture: ((UIImage) -> Void)? = nil
    @State private var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    @State private var capturedImage: UIImage?
    @State private var pendingPrompt = ""
    
    @State private var annotatedImage: UIImage?
    
    var body: some View {
        ZStack {
            switch authorizationStatus {
            case .authorized:
                CameraPreview(currentZoom: $currentZoom, totalZoom: $totalZoom, capturedImage: $capturedImage, annotatedImage: $annotatedImage, pendingPrompt: $pendingPrompt, captureTrigger: captureTrigger, onCapture: onCapture)                    .ignoresSafeArea()
                    .clipShape(Circle())
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
        .onReceive(sendMessage) { message in
            pendingPrompt = message
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

// MARK: - Camera Preview Wrapper

private struct CameraPreview: UIViewRepresentable {
    @Binding var currentZoom: Double
    @Binding var totalZoom: Double
    @Binding var capturedImage: UIImage?
    @Binding var annotatedImage: UIImage?
    @Binding var pendingPrompt: String
    let captureTrigger: Int
    let onCapture: ((UIImage) -> Void)?
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configureSession(on: view)
        
        // Start WebSocket connection
        context.coordinator.setupWebSocket()
        
        // Callback to update the SwiftUI binding when a frame arrives
        context.coordinator.onFrameReceived = { image in
            self.annotatedImage = image
        }
        
        // Continuous capture loop (15 FPS) for WebSocket Streaming
        let timer = Timer.scheduledTimer(withTimeInterval: 1/15, repeats: true) { _ in
            self.captureAndStreamFrame(context: context)
        }
        context.coordinator.streamingTimer = timer
        
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.updateZoom(to: currentZoom + totalZoom)
        
        // Handle manual capture trigger (HTTP Query)
        if !pendingPrompt.isEmpty {
            // Capture the prompt value NOW before the async snapshot clears it
            let promptToSend = pendingPrompt
            context.coordinator.requestSnapshot { image in
                guard let img = image else { return }
                DispatchQueue.main.async {
                    self.capturedImage = img
                }
                context.coordinator.makeInferenceHTTP(prompt: promptToSend, image: img)
            }
            DispatchQueue.main.async {
                self.pendingPrompt = ""
            }
        }
    }
    
    func captureAndStreamFrame(context: Context) {
        context.coordinator.requestSnapshot { image in
            guard let img = image else { return }
            DispatchQueue.main.async {
                self.capturedImage = img
            }
            context.coordinator.sendFrameWS(image: img)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    // MARK: - Coordinator (Handles Camera & Network)
    
    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        // --- Camera Properties ---
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "camera.session.queue")
        private var device: AVCaptureDevice?
        private var deviceLockAcquired = false
        private let videoOutput = AVCaptureVideoDataOutput()
        private let outputQueue = DispatchQueue(label: "camera.video.output.queue")
        private let ciContext = CIContext()
        private var pendingSnapshotRequests: [((UIImage?) -> Void)] = []
        
        // --- Network Properties ---
        private var webSocketTask: URLSessionWebSocketTask?
        var onFrameReceived: ((UIImage) -> Void)?
        var streamingTimer: Timer?
        
        struct InferenceWSSchema: Codable {
            let frame: String
        }
        
        struct InferenceHTTPSchema: Codable {
            let prompt: String
            let frame: String
        }
        
        struct InferenceHTTPResponse: Codable {
            let response: String
        }
        
        // 1. Setup WebSocket
        func setupWebSocket() {
            guard let url = URL(string: "wss://\(ENDPOINT_URL_BASE)/ws") else {
                print("❌ Invalid WS URL")
                return
            }
            webSocketTask = URLSession.shared.webSocketTask(with: url)
            webSocketTask?.resume()
            listenForMessages()
        }
        
        // 2. Recursive Listener with auto-reconnect
        private func listenForMessages() {
            webSocketTask?.receive { [weak self] result in
                guard let self = self else { return }
                
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.listenForMessages() // Recursion
                case .failure(let error):
                    print("❌ WebSocket Receive Error: \(error). Reconnecting...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.setupWebSocket()
                    }
                }
            }
        }
        
        // 3. Robust Decoding
        private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
            switch message {
            case .string(let imageB64):
                var sanitized = imageB64.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                
                if let commaRange = sanitized.range(of: ",") {
                    sanitized = String(sanitized[commaRange.upperBound...])
                }
                
                if let imageData = Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters),
                    let image = UIImage(data: imageData) {
                    DispatchQueue.main.async { self.onFrameReceived?(image) }
                }
            case .data(let data):
                if let image = UIImage(data: data) {
                    DispatchQueue.main.async { self.onFrameReceived?(image) }
                }
            @unknown default: break
            }
        }
        
        // 4. Send Frame (WebSocket) — send as text for maximum proxy compatibility
        func sendFrameWS(image: UIImage) {
            guard let frameB64 = image.base64EncodedString() else { return }
            let schema = InferenceWSSchema(frame: frameB64)
            
            do {
                let jsonData = try JSONEncoder().encode(schema)
                guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error = error { print("❌ WS Send Error: \(error)") }
                }
            } catch {
                print("❌ JSON Error: \(error)")
            }
        }
        
        // 5. Make Inference (HTTP POST) - RESTORED
        func makeInferenceHTTP(prompt: String, image: UIImage) {
            guard let url = URL(string: "https://\(ENDPOINT_URL_BASE)/query") else { return }
            guard let frameB64 = image.base64EncodedString() else { return }
            
            let post = InferenceHTTPSchema(
                prompt: prompt,
                frame: frameB64
            )
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            do {
                let jsonData = try JSONEncoder().encode(post)
                request.httpBody = jsonData
                
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        print("❌ HTTP Error: \(error.localizedDescription)")
                        return
                    }
                    if let data = data {
                        Task { @MainActor in
                            do {
                                let result = try JSONDecoder().decode(InferenceHTTPResponse.self, from: data)
                                receiveMessage.send(result.response)
                            } catch {
                                print("❌ HTTP Decoding Error: \(error)")
                            }
                        }
                    }
                }
                
                task.resume()
            } catch {
                print("❌ HTTP Encoding Error: \(error)")
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
            outputQueue.async { [weak self] in
                self?.pendingSnapshotRequests.append(completion)
            }
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
            guard !pendingSnapshotRequests.isEmpty else { return }
            let requesters = pendingSnapshotRequests
            pendingSnapshotRequests.removeAll()
            
            guard let cg = cgImage(from: sampleBuffer),
                    let masked = circularMaskedImage(from: cg) else {
                requesters.forEach { $0(nil) }
                return
            }
            let uiImage = UIImage(cgImage: masked)
            requesters.forEach { $0(uiImage) }
        }
        
        deinit {
            streamingTimer?.invalidate()
            streamingTimer = nil
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
        // IMPORTANT: Sending Data URI prefix for compatibility
        return "data:image/jpeg;base64,\(base64String)"
    }
}

#Preview {
    CameraView()
}
