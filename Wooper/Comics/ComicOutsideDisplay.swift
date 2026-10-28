import SwiftUI
import AVFoundation

@available(iOS 27.1, *)
struct ComicOutsideBridge: UIViewControllerRepresentable {
    let active: Bool
    func makeUIViewController(context: Context) -> ComicOutsideController { ComicOutsideController() }
    func updateUIViewController(_ controller: ComicOutsideController, context: Context) { controller.setActive(active) }
    static func dismantleUIViewController(_ controller: ComicOutsideController, coordinator: ()) { controller.setActive(false) }
}

/// Camera capture is required by UIKit's camera accessory scene on Duo.
/// Frames are neither recorded nor sent anywhere; only the book artwork is presented.
@available(iOS 27.1, *)
final class ComicOutsideController: UIViewController {
    private let camera = ComicCameraSession()
    private var registration: UISceneAccessoryRegistration?
    private var requested = false
    private var visible = false
    private var permissionTask: Task<Void, Never>?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        reconcile()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        stop()
    }
    func setActive(_ active: Bool) {
        requested = active
        reconcile()
    }
    private func reconcile() {
        guard requested && visible else { stop(); return }
        guard registration == nil, permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard let self else { return }
            self.permissionTask = nil
            guard !Task.isCancelled, self.requested, self.visible else { return }
            guard allowed else {
                ComicLibrary.shared.outsideStatus = "Allow camera access in Settings for outside artwork. Reading still works."
                return
            }
            let configuration = UISceneConfiguration(name: "comic artwork")
            configuration.sceneClass = UIWindowScene.self
            configuration.delegateClass = ComicArtworkSceneDelegate.self
            self.registration = self.registerSceneAccessory(.cameraCapture(sceneConfiguration: configuration))
            self.registration?.isEnabled = true
            ComicLibrary.shared.outsideStatus = nil
            self.camera.start { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.requested && self.visible else { return }
                    ComicLibrary.shared.outsideStatus = message
                }
            }
        }
    }
    private func stop() {
        permissionTask?.cancel(); permissionTask = nil
        if let registration { unregisterSceneAccessory(registration) }
        registration = nil
        camera.stop()
    }
}

private final class ComicCameraSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wooper.comics.camera")
    private let session = AVCaptureSession()
    private var configured = false
    func start(report: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do {
                if !configured {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw ComicImportError.invalid("Camera unavailable; outside artwork is off.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.sessionPreset = .low
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw ComicImportError.invalid("Camera unavailable; outside artwork is off.")
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
                report(session.isRunning ? nil : "Outside artwork is unavailable right now.")
            } catch { report(error.localizedDescription) }
        }
    }
    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }
}

@available(iOS 27.1, *)
final class ComicArtworkSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ComicArtworkView())
        window.makeKeyAndVisible()
        self.window = window
    }
    func sceneDidDisconnect(_ scene: UIScene) { window = nil }
}

private struct ComicArtworkView: View {
    @State private var library = ComicLibrary.shared
    var body: some View {
        ZStack {
            Color(red: 0.97, green: 0.95, blue: 0.87).ignoresSafeArea()
            if let cover = library.currentBook?.coverFile {
                GeometryReader { geometry in
                    ComicPageImage(page: ComicPage(file: cover), fill: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            } else {
            VStack(spacing: 20) {
                Text("calvin & hobbes")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                if let cover = library.currentBook?.pages.first {
                    ComicPageImage(page: cover)
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 96, weight: .light))
                    Text("a little time for reading")
                        .font(.system(size: 16, design: .serif)).italic()
                }
            }
            .padding(28)
            .foregroundStyle(Color(red: 0.22, green: 0.20, blue: 0.15))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
