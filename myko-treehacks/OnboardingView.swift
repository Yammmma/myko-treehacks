import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Binding var isPresented: Bool
//    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var currentPage = 0
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micStatus = AVAudioSession.sharedInstance().recordPermission

    var body: some View {
        TabView(selection: $currentPage) {
            OnboardingPage(
                imageName: "myko-micro",
                title: "AI Microscopy in Your Pocket",
                body1: "Capture and analyze microscopic samples instantly with on-device intelligence.",
                buttonTitle: "Continue",
                pageIndex: 0,
                currentPage: $currentPage,
                primaryAction: advancePage
            )
            .tag(0)

            OnboardingPage(
                imageName: "myko-position1",
                title: "Camera Access Required",
                body1: "Myko uses your camera to capture microscope images for analysis.",
                buttonTitle: cameraButtonTitle,
                pageIndex: 1,
                currentPage: $currentPage,
                primaryAction: handleCameraAction
            )
            .tag(1)

            OnboardingPage(
                imageName: "myko-position2",
                title: "Voice Dictation",
                body1: "Use your voice to describe samples and add notes hands-free.",
                buttonTitle: micButtonTitle,
                pageIndex: 2,
                currentPage: $currentPage,
                primaryAction: handleMicAction,
                secondaryActionTitle: "Skip for now",
                secondaryAction: advancePage
            )
            .tag(2)

            OnboardingPage(
                imageName: "myko-position3",
                title: "You’re Ready to Scan",
                body1: "Place your sample under the microscope and tap Scan to begin.",
                buttonTitle: "Start Using Myko",
                pageIndex: 3,
                currentPage: $currentPage,
                primaryAction: completeOnboarding
            )
            .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Color(.systemBackground))
        .onAppear {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            micStatus = AVAudioSession.sharedInstance().recordPermission
        }
    }

    private var cameraButtonTitle: String {
        cameraStatus == .authorized ? "Continue" : "Enable Camera"
    }

    private var micButtonTitle: String {
        micStatus == .granted ? "Continue" : "Enable Microphone"
    }

    private func advancePage() {
        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage = min(currentPage + 1, 3)
        }
    }

    private func handleCameraAction() {
        switch cameraStatus {
        case .authorized:
            advancePage()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraStatus = granted ? .authorized : .denied
                    if granted {
                        advancePage()
                    }
                }
            }
        case .denied, .restricted:
            openSettings()
        @unknown default:
            break
        }
    }

    private func handleMicAction() {
        switch micStatus {
        case .granted:
            advancePage()
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    micStatus = granted ? .granted : .denied
                    if granted {
                        advancePage()
                    }
                }
            }
        case .denied:
            openSettings()
        @unknown default:
            break
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func completeOnboarding() {
//        hasSeenOnboarding = true
        isPresented = false
    }
}

private struct OnboardingPage: View {
    let imageName: String
    let title: String
    let body1: String
    let buttonTitle: String
    let pageIndex: Int
    @Binding var currentPage: Int
    let primaryAction: () -> Void
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    @State private var animateImage = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .opacity(animateImage ? 1 : 0)
                .offset(y: animateImage ? 0 : 12)
                .padding(.horizontal, 24)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .padding(.horizontal, 24)

            Text(body1)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            Spacer()

            Button(action: primaryAction) {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(MykoColors.leafBase)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 24)

            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            Color.clear
                .frame(height: 32)
        }
        .onAppear {
            if currentPage == pageIndex {
                withAnimation(.easeOut(duration: 0.25)) {
                    animateImage = true
                }
            }
        }
        .onChange(of: currentPage) { _, newValue in
            if newValue == pageIndex {
                animateImage = false
                withAnimation(.easeOut(duration: 0.25)) {
                    animateImage = true
                }
            }
        }
    }
}
