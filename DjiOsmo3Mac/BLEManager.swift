import Foundation
import CoreBluetooth
import Combine

// MARK: - BLE event stream

enum BLEEvent {
    case stateChanged(CBManagerState)
    case discovered([DiscoveredPeripheral])
    case connected(DiscoveredPeripheral)
    case disconnected(String?)          // localizedDescription or nil
    case ready                          // characteristics resolved, notifications subscribed
    case received(DUMLFrame)
    case log(String)
}

// MARK: - Service protocol (enables dependency injection and testing)

protocol BLEServicing: AnyObject {
    /// Reactive event stream — subscribe once and handle all BLE lifecycle events.
    var events: AnyPublisher<BLEEvent, Never> { get }
    /// Snapshot of currently discovered peripherals.
    var discovered: [UUID: DiscoveredPeripheral] { get }

    func startScan()
    func stopScan()
    func connect(_ id: UUID)
    func disconnect()
    func writeDUML(_ frame: DUMLFrame, encoded: [UInt8]?)
    func writePairingTrigger()
}

// MARK: - Peripheral model

struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

// MARK: - CoreBluetooth UUIDs

private extension CBUUID {
    static let osmoService = CBUUID(string: DUML.BLEUUID.service)
    static let charFFF3    = CBUUID(string: DUML.BLEUUID.charFFF3)
    static let charFFF4    = CBUUID(string: DUML.BLEUUID.charFFF4)
    static let charFFF5    = CBUUID(string: DUML.BLEUUID.charFFF5)
}

// MARK: - BLEManager

final class BLEManager: NSObject, BLEServicing {

    // Public reactive interface — backed by a PassthroughSubject.
    private let subject = PassthroughSubject<BLEEvent, Never>()
    var events: AnyPublisher<BLEEvent, Never> { subject.eraseToAnyPublisher() }

    private(set) var discovered: [UUID: DiscoveredPeripheral] = [:]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var charFFF3: CBCharacteristic?
    private var charFFF4: CBCharacteristic?
    private var charFFF5: CBCharacteristic?

    private let parser = DUMLStreamParser()
    private let matchedNameKeywords = ["Osmo", "OM", "DJI"]

    override init() {
        super.init()
        // All delegate callbacks delivered on main queue — keeps subject.send() thread-safe.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: BLEServicing

    func startScan() {
        guard central.state == .poweredOn else {
            subject.send(.log("BLE not powered on (state=\(central.state.rawValue))"))
            return
        }
        discovered.removeAll()
        subject.send(.discovered([]))
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        subject.send(.log("Scanning for DJI/Osmo peripherals…"))
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
    }

    func connect(_ id: UUID) {
        stopScan()
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            subject.send(.log("Peripheral \(id) not in cache"))
            return
        }
        peripheral = p
        p.delegate = self
        subject.send(.log("Connecting to \(p.name ?? p.identifier.uuidString)…"))
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func writeDUML(_ frame: DUMLFrame, encoded: [UInt8]? = nil) {
        guard let p = peripheral, let c = charFFF5 else {
            subject.send(.log("writeDUML: not connected"))
            return
        }
        let data = Data(encoded ?? frame.encode())
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            p.writeValue(data.subdata(in: offset..<end), for: c, type: .withoutResponse)
            offset = end
        }
    }

    func writePairingTrigger() {
        guard let p = peripheral else { return }
        let payload = Data([0x01, 0x00])
        if let c = charFFF4 {
            p.writeValue(payload, for: c, type: .withResponse)
            subject.send(.log("Pairing trigger → FFF4"))
        } else if let c = charFFF3 {
            p.writeValue(payload, for: c, type: .withResponse)
            subject.send(.log("Pairing trigger → FFF3 (FFF4 unavailable)"))
        }
    }

    // MARK: Helpers

    private func looksLikeOsmo(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return matchedNameKeywords.contains { name.localizedCaseInsensitiveContains($0) }
    }

    private func emitDiscovered() {
        subject.send(.discovered(discovered.values.sorted { $0.rssi > $1.rssi }))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        subject.send(.stateChanged(central.state))
        subject.send(.log("BLE state: \(central.state.label)"))
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName  = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name     = advName ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasOsmoService = services.contains { $0.uuidString.uppercased().hasPrefix("FFF0") }
        guard hasOsmoService || looksLikeOsmo(name) else { return }

        let device = DiscoveredPeripheral(id: peripheral.identifier,
                                          name: name.isEmpty ? "Unknown" : name,
                                          rssi: RSSI.intValue)
        discovered[device.id] = device
        emitDiscovered()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let dev = DiscoveredPeripheral(id: peripheral.identifier,
                                       name: peripheral.name ?? "Unknown",
                                       rssi: 0)
        subject.send(.connected(dev))
        subject.send(.log("Connected. Discovering services…"))
        peripheral.discoverServices([.osmoService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        subject.send(.disconnected(error?.localizedDescription))
        subject.send(.log("Connect failed: \(error?.localizedDescription ?? "?")"))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        charFFF3 = nil; charFFF4 = nil; charFFF5 = nil
        Task { @MainActor [weak self] in await self?.parser.reset() }
        subject.send(.disconnected(error?.localizedDescription))
        subject.send(.log("Disconnected" + (error.map { ": \($0.localizedDescription)" } ?? "")))
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            subject.send(.log("discoverServices error: \(error.localizedDescription)"))
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == .osmoService }) else {
            subject.send(.log("Service FFF0 not found"))
            return
        }
        peripheral.discoverCharacteristics([.charFFF3, .charFFF4, .charFFF5], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            subject.send(.log("discoverChars error: \(error.localizedDescription)"))
            return
        }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case .charFFF3: charFFF3 = c
            case .charFFF4: charFFF4 = c
            case .charFFF5: charFFF5 = c
            default: break
            }
        }
        subject.send(.log("Chars: FFF3=\(charFFF3 != nil), FFF4=\(charFFF4 != nil), FFF5=\(charFFF5 != nil)"))
        for c in [charFFF3, charFFF4, charFFF5].compactMap({ $0 }) {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        subject.send(.ready)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            subject.send(.log("notify(\(characteristic.uuid)) error: \(error.localizedDescription)"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let chunk = [UInt8](data)
        // Hop to the DUMLStreamParser actor, then return to main to emit the frames.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let frames = await self.parser.append(chunk)
            for f in frames { self.subject.send(.received(f)) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            subject.send(.log("write(\(characteristic.uuid)) error: \(error.localizedDescription)"))
        }
    }
}

// MARK: - CBManagerState display

private extension CBManagerState {
    var label: String {
        switch self {
        case .unknown:     return "unknown"
        case .resetting:   return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff:  return "poweredOff"
        case .poweredOn:   return "poweredOn"
        @unknown default:  return "?"
        }
    }
}
