import AVFoundation
import CoreMedia

// MARK: - CaptureMode

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo      = "Photo"
    case video      = "Video"
    case timelapse  = "Timelapse"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .photo:     return "camera"
        case .video:     return "video"
        case .timelapse: return "timer"
        }
    }
}

// MARK: - CameraManager

@MainActor
final class CameraManager: NSObject, ObservableObject {

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var captureMode: CaptureMode = .video
    @Published var zoomFactor: CGFloat = 1.0
    @Published var isBursting = false
    @Published var isTimelapsing = false

    // Timelapse
    @Published var timelapseInterval: TimeInterval = 2.0
    private var timelapseTimer: Timer?
    @Published var timelapseCount: Int = 0

    // Continuity Camera effects — class-level on AVCaptureDevice, mirrored for SwiftUI.
    // Center Stage is settable; Portrait mode is read-only (user controls via Control Center).
    @Published var centerStageEnabled: Bool = AVCaptureDevice.isCenterStageEnabled
    @Published var portraitEffectActive: Bool = AVCaptureDevice.isPortraitEffectEnabled

    // Called on a background queue with each video frame (for TrackingEngine).
    // nonisolated(unsafe) so the AVCaptureVideoDataOutputSampleBufferDelegate
    // can read it without a MainActor hop on every frame.
    nonisolated(unsafe) var frameHandler: ((CMSampleBuffer) -> Void)?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private var currentInput: AVCaptureDeviceInput?
    private var burstTimer: Timer?
    private var recordingURL: URL?

    override init() {
        super.init()
        discoverCameras()
        observeDeviceConnections()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Discovery

    func discoverCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices
        if selectedCamera == nil {
            selectedCamera = availableCameras.first
        }
    }

    /// True when a Continuity Camera iPhone is in the available list.
    var continuityCamera: AVCaptureDevice? {
        availableCameras.first { $0.deviceType == .continuityCamera }
    }

    func isContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera
    }

    // MARK: Continuity Camera effects

    // Center Stage and Portrait Effect are class-level (global) on AVCaptureDevice —
    // they affect all cameras system-wide, not just one device instance.

    func setCenterStage(_ enabled: Bool) {
        AVCaptureDevice.isCenterStageEnabled = enabled
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
    }

    private func refreshEffectStates() {
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
        portraitEffectActive = AVCaptureDevice.isPortraitEffectEnabled
    }

    // MARK: Dynamic device connection observation

    private func observeDeviceConnections() {
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleDeviceConnected(_:)),
                       name: AVCaptureDevice.wasConnectedNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleDeviceDisconnected(_:)),
                       name: AVCaptureDevice.wasDisconnectedNotification,
                       object: nil)
    }

    @objc private func handleDeviceConnected(_ note: Notification) {
        Task { @MainActor in
            let prev = availableCameras
            discoverCameras()
            // Auto-switch to Continuity Camera when iPhone first appears
            if let iphone = continuityCamera, !prev.contains(iphone) {
                switchCamera(iphone)
            }
        }
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        Task { @MainActor in
            discoverCameras()
            // If the disconnected device was selected, fall back to first available
            if let gone = note.object as? AVCaptureDevice, gone == selectedCamera {
                if let fallback = availableCameras.first {
                    switchCamera(fallback)
                } else {
                    stop()
                }
            }
            refreshEffectStates()
        }
    }

    // MARK: Session lifecycle

    func start(camera: AVCaptureDevice? = nil) {
        let device = camera ?? selectedCamera ?? AVCaptureDevice.default(for: .video)
        guard let device else { return }
        selectedCamera = device

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: device)
            if !self.session.isRunning {
                self.session.startRunning()
            }
            Task { @MainActor in self.isRunning = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            Task { @MainActor in self?.isRunning = false }
        }
    }

    func switchCamera(_ device: AVCaptureDevice) {
        selectedCamera = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let old = self.currentInput { self.session.removeInput(old) }
            self.addInput(device)
            self.session.commitConfiguration()
        }
        refreshEffectStates()
    }

    func switchToNextCamera() {
        guard availableCameras.count > 1, let current = selectedCamera else { return }
        let idx = availableCameras.firstIndex(of: current) ?? 0
        let next = availableCameras[(idx + 1) % availableCameras.count]
        switchCamera(next)
    }

    // MARK: Zoom
    // macOS AVCaptureDevice has no videoZoomFactor — zoom is applied visually
    // via the preview layer's affineTransform in CameraPreviewView.

    func setZoom(_ factor: CGFloat) {
        zoomFactor = max(1.0, min(factor, 8.0))
    }

    func adjustZoom(delta: CGFloat) {
        setZoom(zoomFactor + delta)
    }

    // MARK: Preview layer

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: Photo capture

    func capturePhoto(timer delaySeconds: TimeInterval = 0) {
        guard captureMode == .photo || captureMode == .timelapse else { return }
        if delaySeconds > 0 {
            Task {
                try? await Task.sleep(for: .seconds(delaySeconds))
                await MainActor.run { self.shootPhoto() }
            }
        } else {
            shootPhoto()
        }
    }

    private func shootPhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func startBurst() {
        guard captureMode == .photo, !isBursting else { return }
        isBursting = true
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.shootPhoto() }
        }
    }

    func stopBurst() {
        burstTimer?.invalidate()
        burstTimer = nil
        isBursting = false
    }

    // MARK: Video recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard captureMode == .video, !isRecording else { return }
        let url = makeOutputURL(ext: "mov")
        recordingURL = url
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        sessionQueue.async { [weak self] in self?.movieOutput.stopRecording() }
    }

    // MARK: Timelapse

    func startTimelapse() {
        guard captureMode == .timelapse, !isTimelapsing else { return }
        timelapseCount = 0
        isTimelapsing = true
        timelapseTimer = Timer.scheduledTimer(withTimeInterval: timelapseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.shootPhoto()
                self?.timelapseCount += 1
            }
        }
    }

    func stopTimelapse() {
        timelapseTimer?.invalidate()
        timelapseTimer = nil
        isTimelapsing = false
    }

    // MARK: Private helpers

    private func configureSession(for device: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        if let old = currentInput { session.removeInput(old) }
        addInput(device)

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frames", qos: .userInitiated))
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }

        session.commitConfiguration()
    }

    private func addInput(_ device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        currentInput = input
    }

    private func makeOutputURL(ext: String) -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let name = "osmo-\(Int(Date().timeIntervalSince1970)).\(ext)"
        return dir.appendingPathComponent(name)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let url = {
            let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            return dir.appendingPathComponent("osmo-\(Int(Date().timeIntervalSince1970)).jpg")
        }()
        try? data.write(to: url)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.isRecording = true }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in self.isRecording = false }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        frameHandler?(sampleBuffer)
    }
}
