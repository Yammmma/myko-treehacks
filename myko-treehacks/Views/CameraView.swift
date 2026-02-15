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
                        GeometryReader { geometry in
                            let image = endpoint.annotatedImage ?? capturedImage
                            let previewBounds = CGRect(origin: .zero, size: geometry.size)
                            let fittedBounds = aspectFitRect(for: image.size, in: previewBounds)
                            
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            BoundingBoxOverlay(
                                normalizedRect: $endpoint.boundingBoxNormalized,
                                bounds: fittedBounds,
                                isVisible: endpoint.isBoundingBoxVisible                           )
                        }                    } else {
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

private func aspectFitRect(for imageSize: CGSize, in container: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
        return container
    }
    
    let imageAspect = imageSize.width / imageSize.height
    let containerAspect = container.width / container.height
    
    if imageAspect > containerAspect {
        let fittedHeight = container.width / imageAspect
        let originY = container.minY + (container.height - fittedHeight) / 2
        return CGRect(x: container.minX, y: originY, width: container.width, height: fittedHeight)
    } else {
        let fittedWidth = container.height * imageAspect
        let originX = container.minX + (container.width - fittedWidth) / 2
        return CGRect(x: originX, y: container.minY, width: fittedWidth, height: container.height)
    }
}

private enum RectConversion {
    static func normalizedRect(from viewRect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let x = (viewRect.minX - bounds.minX) / bounds.width
        let y = (viewRect.minY - bounds.minY) / bounds.height
        let width = viewRect.width / bounds.width
        let height = viewRect.height / bounds.height
        return clampNormalizedRect(CGRect(x: x, y: y, width: width, height: height))
    }
    
    static func viewRect(from normalizedRect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + normalizedRect.minX * bounds.width,
            y: bounds.minY + normalizedRect.minY * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
    }
}


private func clampNormalizedRect(_ rect: CGRect) -> CGRect {
    let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
    let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
    let maxX = max(minX, min(rect.maxX, bounds.maxX))
    let maxY = max(minY, min(rect.maxY, bounds.maxY))
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private struct BoundingBoxOverlay: View {
    @Binding var normalizedRect: CGRect
    let bounds: CGRect
    let isVisible: Bool
    
    @State private var dragStartRect: CGRect = .zero
    @State private var resizeStartRect: CGRect = .zero
    
    private let minimumNormalizedSize: CGFloat = 0.12
    private let handleSize: CGFloat = 24
    
    var body: some View {
        if !isVisible {
            EmptyView()
        } else {
            let viewRect = RectConversion.viewRect(from: normalizedRect, in: bounds)
            
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(
                        Rectangle()
                            .fill(Color.black.opacity(0.08))
                    )
                    .frame(width: viewRect.width, height: viewRect.height)
                    .shadow(color: .white.opacity(0.35), radius: 4)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .offset(x: handleSize * 0.25, y: handleSize * 0.25)
                    .gesture(resizeGesture(viewRect: viewRect))
                    .accessibilityLabel("Resize bounding box")
            }
            .position(x: viewRect.midX, y: viewRect.midY)
            .gesture(dragGesture(viewRect: viewRect))
            .accessibilityLabel("Bounding box")
        }
    }
    
    private func dragGesture(viewRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartRect == .zero { dragStartRect = viewRect }
                let translated = dragStartRect.offsetBy(dx: value.translation.width, dy: value.translation.height)
                let clamped = clampMovingRect(translated, to: bounds)
                normalizedRect = RectConversion.normalizedRect(from: clamped, in: bounds)
            }
            .onEnded { _ in
                dragStartRect = .zero
            }
    }
    
    private func resizeGesture(viewRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartRect == .zero { resizeStartRect = viewRect }
                
                let minWidth = bounds.width * minimumNormalizedSize
                let minHeight = bounds.height * minimumNormalizedSize
                
                var nextWidth = resizeStartRect.width + value.translation.width
                var nextHeight = resizeStartRect.height + value.translation.height
                
                nextWidth = max(minWidth, min(nextWidth, bounds.maxX - resizeStartRect.minX))
                nextHeight = max(minHeight, min(nextHeight, bounds.maxY - resizeStartRect.minY))
                
                let resized = CGRect(x: resizeStartRect.minX, y: resizeStartRect.minY, width: nextWidth, height: nextHeight)
                normalizedRect = RectConversion.normalizedRect(from: resized, in: bounds)
            }
            .onEnded { _ in
                resizeStartRect = .zero            }
    }
}

private func clampMovingRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
    var clamped = rect
    clamped.origin.x = min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
    clamped.origin.y = min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
    return clamped
}


#Preview {
    CameraView(endpoint: EndpointViewModel())
}
