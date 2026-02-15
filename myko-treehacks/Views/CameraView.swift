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
                                isLocked: endpoint.isBoundingBoxLocked
                            )
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
    let isLocked: Bool

    @State private var initialRect: CGRect = .zero

    var body: some View {
        let viewRect = RectConversion.viewRect(from: normalizedRect, in: bounds)

        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isLocked ? Color.gray.opacity(0.8) : Color.white, style: StrokeStyle(lineWidth: 2, dash: isLocked ? [8, 5] : []))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.12))
            )
            .frame(width: viewRect.width, height: viewRect.height)
            .position(x: viewRect.midX, y: viewRect.midY)
            .shadow(color: isLocked ? .black.opacity(0.5) : .white.opacity(0.4), radius: 6)
            .gesture(dragGesture(viewRect: viewRect), including: isLocked ? .none : .all)
            .animation(.easeInOut(duration: 0.2), value: isLocked)
            .accessibilityLabel(isLocked ? "Bounding box locked" : "Bounding box unlocked")
    }

    private func dragGesture(viewRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if initialRect == .zero { initialRect = viewRect }
                let translated = initialRect.offsetBy(dx: value.translation.width, dy: value.translation.height)
                let clamped = clampMovingRect(translated, to: bounds)
                normalizedRect = RectConversion.normalizedRect(from: clamped, in: bounds)
            }
            .onEnded { _ in
                initialRect = .zero
            }
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
