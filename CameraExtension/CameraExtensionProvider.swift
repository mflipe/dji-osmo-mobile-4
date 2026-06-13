import Foundation
import CoreMediaIO
import os.log

// MARK: - Osmo Smart Camera — CMIO Camera Extension (F1 scaffold)
//
// ⚠️ NÃO adicione este arquivo ao target do app `DjiOsmo3Mac`. Ele pertence a um
// *Camera Extension* (System Extension) separado, criado no Xcode via
// File ▸ New ▸ Target ▸ "Camera Extension". Sem esse target ele não compila — e
// não deve compilar dentro do app.
//
// Objetivo (Plano de Produto, Pilar 1 / F1): expor uma câmera virtual do sistema
// "Osmo Smart Camera" para Zoom/Meet/FaceTime, alimentada pelo crop/composição
// dos frames do gimbal + tracking.
//
// Referência:
// developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-coremedia-i-o
//
// Este é um esqueleto mínimo (provider → device → stream) com um gerador de
// frames de teste. Substitua `generateFrame` pela composição real do preview.

private let kFrameRate: Int = 30
private let kWidth: Int32 = 1280
private let kHeight: Int32 = 720

// MARK: Provider

final class OsmoExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: OsmoExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = OsmoExtensionDeviceSource(localizedName: "Osmo Smart Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log(.error, "Falha ao adicionar device: %{public}@", error.localizedDescription)
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Osmo Smart Camera" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: Device

final class OsmoExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: OsmoExtensionStreamSource!

    init(localizedName: String) {
        super.init()
        let deviceID = UUID()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        let dims = CMVideoDimensions(width: kWidth, height: kHeight)
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width, height: dims.height,
            extensions: nil, formatDescriptionOut: &formatDescription)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription!,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(kFrameRate)),
            validFrameDurations: nil)

        streamSource = OsmoExtensionStreamSource(
            localizedName: "Osmo Smart Camera.Video",
            streamID: UUID(),
            streamFormat: streamFormat,
            device: device)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            os_log(.error, "Falha ao adicionar stream: %{public}@", error.localizedDescription)
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { p.model = "Osmo Smart Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

// MARK: Stream

final class OsmoExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "osmo.camera.stream", qos: .userInteractive)
    private var sequence: UInt64 = 0

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = activeFormatIndex }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate))
        t.setEventHandler { [weak self] in self?.emitFrame() }
        t.resume()
        timer = t
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    // Substituir pela composição real (crop digital do preview + tracking).
    private func emitFrame() {
        // TODO(F1): preencher um CVPixelBuffer com o frame composto e enviar via
        // stream.send(_:discontinuity:hostTimeInNanoseconds:). Mantido como
        // scaffold para o target de Camera Extension.
        sequence &+= 1
    }
}
