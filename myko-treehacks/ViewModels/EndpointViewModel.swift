//
//  EndpointViewModel.swift
//  myko-treehacks
//
//  Created by Yuma Soerianto on 2/14/26.
//

import Foundation
import Combine
import UIKit
import SwiftUI
import AVFoundation
import CoreImage
import CoreVideo

let ENDPOINT_URL_BASE = "purple-islands-draw.loca.lt"

final class EndpointViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var capturedImage: UIImage? = nil
    @Published var annotatedImage: UIImage? = nil
    var onCapture: ((UIImage) -> Void)?
    
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
    
    enum CaptureMode {
        case stream // WebSocket
        case query // HTTP POST
        case manualCapture
    }
    
    init(onCapture: ((UIImage) -> Void)? = nil) {
        super.init()
        
        self.onCapture = onCapture
        
        configureSession()
        setupWebSocket()
        
        // Continuous capture loop for WebSocket Streaming
        Timer.scheduledTimer(withTimeInterval: 1/5, repeats: true) { [self] _ in
            captureImage(mode: .stream)
        }
    }
    
    func captureImage(mode: CaptureMode, prompt: String? = nil) {
        requestSnapshot { [self] image in
            guard let img = image else { return }
            
            DispatchQueue.main.async {
                self.capturedImage = img
            }
            
            // Route based on mode
            switch mode {
            case .stream:
                sendFrameWS(image: img)
                break
            case .query:
                guard let prompt else {
                    print("Can't make inference without prompt!")
                    return
                }
                
                makeInferenceHTTP(prompt: prompt, image: img)
            case .manualCapture:
                onCapture?(img)
            }
        }
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
    
    // 2. Recursive Listener
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.listenForMessages() // Recursion
            case .failure(let error):
                print("❌ WebSocket Receive Error: \(error)")
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
                DispatchQueue.main.async { self.annotatedImage = image }
            }
        case .data(let data):
            if let image = UIImage(data: data) {
                DispatchQueue.main.async { self.annotatedImage = image }
            }
        @unknown default: break
        }
    }
    
    // 4. Send Frame (WebSocket)
    func sendFrameWS(image: UIImage) {
        guard let frameB64 = image.base64EncodedString() else { return }
        let schema = InferenceWSSchema(frame: frameB64)
        
        do {
            let jsonData = try JSONEncoder().encode(schema)
            let message = URLSessionWebSocketTask.Message.data(jsonData)
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
    
    func configureSession() {
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
        let size = min(width, height)
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        
        let radius = CGFloat(size) / 2.0
        let center = CGPoint(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
        let rect = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
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
        
//            let uiImage = UIImage(named: "cell4")
        
        requesters.forEach { $0(uiImage) }
    }
    
    deinit {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        if deviceLockAcquired {
            device?.unlockForConfiguration()
        }
        if session.isRunning { session.stopRunning() }
    }
}
