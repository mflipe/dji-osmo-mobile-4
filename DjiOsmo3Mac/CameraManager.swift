import AVFoundation
import CoreMedia
import Combine

// MARK: - CaptureMode

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo     = "Photo"
    case video     = "Video"
    case timelapse = "Timelapse"

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

    // MARK: Published state

    @Published var availableCameras:     [AVCaptureDevice] = []
    @Published var selectedCamera:       AVCaptureDevice?
    @Published var availableMicrophones: [AVCaptureDevice] = []
    @Published var selectedMicrophone:   AVCaptureDevice?
    @Published var isRunning    = false
    @Published var isRecording  = false
    @Published var captureMode: CaptureMode = .video
    @Published var zoomFactor:  CGFloat = 1.0
    @Published var isBursting    = false
    @Published var isTimelapsing = false
    @Published var timelapseInterval: TimeInterval = 2.0
    @Published var timelapseCount = 0
    @Published var centerStageEnabled: Bool = AVCaptureDevice.isCenterStageEnabled
    @Published var portraitEffectActive: Bool = AVCaptureDevice.isPortraitEffectEnabled

    // Frame delivery to TrackingEngine — called on background queue.
    nonisolated(unsafe) var frameHandler: ((CMSampleBuffer) -> Void)?

    // MARK: AVFoundation session

    let session = AVCaptureSession()
    private let photoOutput      = AVCapturePhotoOutput()
    private let movieOutput      = AVCaptureMovieFileOutput()
    private let videoDataOutput  = AVCaptureVideoDataOutput()
    private let sessionQueue     = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private var currentInput:      AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?
    private var recordingURL: URL?

    // MARK: Combine

    private var cancellables        = Set<AnyCancellable>()
    private var timelapseCancellable: AnyCancellable?
    private var burstCancellable:     AnyCancellable?

    // MARK: Init

    override init() {
        super.init()
        discoverDevices()
        observeDeviceConnections()
    }

    // MARK: Device discovery

    func discoverDevices() {
        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        availableCameras = videoDiscovery.devices
        if selectedCamera == nil { selectedCamera = availableCameras.first }

        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio, position: .unspecified)
        let allMics = audioDiscovery.devices
        // Prefer hardware microphones over virtual/software devices (BlackHole, etc.)
        // to avoid AVCaptureMovieFileOutput codec init errors.
        let hardware = allMics.filter {
            !$0.localizedName.localizedCaseInsensitiveContains("virtual") &&
            !$0.localizedName.localizedCaseInsensitiveContains("blackhole") &&
            !$0.localizedName.localizedCaseInsensitiveContains("loopback")
        }
        availableMicrophones = hardware.isEmpty ? allMics : hardware
        if selectedMicrophone == nil { selectedMicrophone = availableMicrophones.first }
    }

    var continuityCamera: AVCaptureDevice? {
        availableCameras.first { $0.deviceType == .continuityCamera }
    }

    func isContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera
    }

    // MARK: Continuity Camera effects

    func setCenterStage(_ enabled: Bool) {
        AVCaptureDevice.isCenterStageEnabled = enabled
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
    }

    private func refreshEffectStates() {
        centerStageEnabled  = AVCaptureDevice.isCenterStageEnabled
        portraitEffectActive = AVCaptureDevice.isPortraitEffectEnabled
    }

    // MARK: Device connection observation (Combine replaces NotificationCenter addObserver)

    private func observeDeviceConnections() {
        NotificationCenter.default
            .publisher(for: AVCaptureDevice.wasConnectedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDeviceConnected() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVCaptureDevice.wasDisconnectedNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? AVCaptureDevice }
            .sink { [weak self] device in self?.handleDeviceDisconnected(device) }
            .store(in: &cancellables)
    }

    private func handleDeviceConnected() {
        let prev = availableCameras
        discoverDevices()
        if let iphone = continuityCamera, !prev.contains(iphone) { switchCamera(iphone) }
        if selectedMicrophone == nil, let mic = availableMicrophones.first { switchMicrophone(mic) }
    }

    private func handleDeviceDisconnected(_ gone: AVCaptureDevice) {
        discoverDevices()
        if gone == selectedCamera {
            if let fallback = availableCameras.first { switchCamera(fallback) } else { stop() }
        }
        if gone == selectedMicrophone {
            if let fallback = availableMicrophones.first { switchMicrophone(fallback) }
            else { selectedMicrophone = nil }
        }
        refreshEffectStates()
    }

    // MARK: Session lifecycle

    func start(camera: AVCaptureDevice? = nil) {
        let device = camera ?? selectedCamera ?? AVCaptureDevice.default(for: .video)
        guard let device else { return }
        selectedCamera = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(for: device)
            if !self.session.isRunning { self.session.startRunning() }
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
            self.addVideoInput(device)
            self.session.commitConfiguration()
        }
        refreshEffectStates()
    }

    func switchMicrophone(_ device: AVCaptureDevice) {
        selectedMicrophone = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let old = self.currentAudioInput { self.session.removeInput(old) }
            self.addAudioInput(device)
            self.session.commitConfiguration()
        }
    }

    func switchToNextCamera() {
        guard availableCameras.count > 1, let current = selectedCamera else { return }
        let idx  = availableCameras.firstIndex(of: current) ?? 0
        switchCamera(availableCameras[(idx + 1) % availableCameras.count])
    }

    // MARK: Zoom (applied via preview layer transform — no hardware zoom on macOS)

    func setZoom(_ factor: CGFloat) { zoomFactor = max(1, min(factor, 8)) }
    func adjustZoom(delta: CGFloat) { setZoom(zoomFactor + delta) }

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
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    // MARK: Burst (Combine timer replaces Timer.scheduledTimer)

    func startBurst() {
        guard captureMode == .photo, !isBursting else { return }
        isBursting = true
        burstCancellable = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.shootPhoto() }
    }

    func stopBurst() {
        burstCancellable = nil
        isBursting = false
    }

    // MARK: Video recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        guard captureMode == .video, !isRecording else { return }
        let url = makeOutputURL(ext: "mov")
        recordingURL = url
        sessionQueue.async { [weak self] in self?.movieOutput.startRecording(to: url, recordingDelegate: self!) }
    }

    func stopRecording() {
        guard isRecording else { return }
        sessionQueue.async { [weak self] in self?.movieOutput.stopRecording() }
    }

    // MARK: Timelapse (Combine timer replaces Timer.scheduledTimer)

    func startTimelapse() {
        guard captureMode == .timelapse, !isTimelapsing else { return }
        timelapseCount = 0
        isTimelapsing = true
        timelapseCancellable = Timer.publish(every: timelapseInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.shootPhoto()
                self.timelapseCount += 1
            }
    }

    func stopTimelapse() {
        timelapseCancellable = nil
        isTimelapsing = false
    }

    // MARK: Private session configuration

    private func configureSession(for device: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if let old = currentInput { session.removeInput(old) }
        addVideoInput(device)
        if let old = currentAudioInput { session.removeInput(old) }
        if let mic = selectedMicrophone { addAudioInput(mic) }
        if session.canAddOutput(photoOutput)     { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput)     { session.addOutput(movieOutput) }
        videoDataOutput.setSampleBufferDelegate(self,
            queue: DispatchQueue(label: "camera.frames", qos: .userInitiated))
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
        session.commitConfiguration()
    }

    private func addVideoInput(_ device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        currentInput = input
    }

    private func addAudioInput(_ device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        currentAudioInput = input
    }

    private func makeOutputURL(ext: String) -> URL {
        let dir  = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("osmo-\(Int(Date().timeIntervalSince1970)).\(ext)")
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("osmo-\(Int(Date().timeIntervalSince1970)).jpg")
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
