import Foundation
import CoreBluetooth

// CoreBluetooth UUIDs from short hex.
private extension CBUUID {
    static let osmoService = CBUUID(string: DUML.BLEUUID.service)
    static let charFFF3    = CBUUID(string: DUML.BLEUUID.charFFF3)
    static let charFFF4    = CBUUID(string: DUML.BLEUUID.charFFF4)
    static let charFFF5    = CBUUID(string: DUML.BLEUUID.charFFF5)
}

struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

protocol BLEManagerDelegate: AnyObject {
    func bleStateChanged(_ state: CBManagerState)
    func bleDiscovered(_ devices: [DiscoveredPeripheral])
    func bleConnected(_ device: DiscoveredPeripheral)
    func bleDisconnected(_ error: Error?)
    func bleReady() // characteristics resolved, notifications subscribed
    func bleReceived(_ frame: DUMLFrame)
    func bleLog(_ message: String)
}

final class BLEManager: NSObject {

    weak var delegate: BLEManagerDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var charFFF3: CBCharacteristic?
    private var charFFF4: CBCharacteristic?
    private var charFFF5: CBCharacteristic?

    private(set) var discovered: [UUID: DiscoveredPeripheral] = [:]
    private let parser = DUMLStreamParser()

    private(set) var state: CBManagerState = .unknown {
        didSet { delegate?.bleStateChanged(state) }
    }

    private var matchedNameKeywords = ["Osmo", "OM", "DJI"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: API

    func startScan() {
        guard central.state == .poweredOn else {
            delegate?.bleLog("BLE not powered on (state=\(central.state.rawValue))")
            return
        }
        discovered.removeAll()
        delegate?.bleDiscovered([])
        // Scan with the FFF0 service filter; some OM3 advertisements omit it,
        // so a name-keyword fallback is applied in didDiscover.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        delegate?.bleLog("Scanning for DJI/Osmo peripherals…")
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
    }

    func connect(_ id: UUID) {
        stopScan()
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first
                  ?? peripheralByID(id) else {
            delegate?.bleLog("Peripheral \(id) not in cache")
            return
        }
        peripheral = p
        p.delegate = self
        delegate?.bleLog("Connecting to \(p.name ?? p.identifier.uuidString)…")
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // Writes a fully-encoded DUML frame to FFF5 (the data channel).
    // Pass pre-encoded bytes to avoid a redundant encode() call.
    func writeDUML(_ frame: DUMLFrame, encoded: [UInt8]? = nil) {
        guard let p = peripheral, let c = charFFF5 else {
            delegate?.bleLog("writeDUML: not connected")
            return
        }
        let bytes = encoded ?? frame.encode()
        let data = Data(bytes)
        // Chunk to MTU. Default ATT MTU is 23 (20 byte payload). If the
        // negotiated MTU is larger CoreBluetooth reports it via maximumWriteValueLength.
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            p.writeValue(data.subdata(in: offset..<end), for: c, type: .withoutResponse)
            offset = end
        }
    }

    // Pairing trigger: writes [0x01, 0x00] to FFF4 (with response).
    // Falls back to FFF3 if FFF4 is missing.
    func writePairingTrigger() {
        guard let p = peripheral else { return }
        let payload = Data([0x01, 0x00])
        if let c = charFFF4 {
            p.writeValue(payload, for: c, type: .withResponse)
            delegate?.bleLog("Pairing trigger → FFF4")
        } else if let c = charFFF3 {
            p.writeValue(payload, for: c, type: .withResponse)
            delegate?.bleLog("Pairing trigger → FFF3 (FFF4 unavailable)")
        }
    }

    // MARK: Helpers

    private func peripheralByID(_ id: UUID) -> CBPeripheral? {
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func looksLikeOsmo(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return matchedNameKeywords.contains { name.localizedCaseInsensitiveContains($0) }
    }

    private func emitDiscovered() {
        let arr = discovered.values.sorted { $0.rssi > $1.rssi }
        delegate?.bleDiscovered(arr)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        delegate?.bleLog("BLE state: \(state.label)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisesOsmo = services.contains(where: { $0.uuidString.uppercased().hasPrefix("FFF0") })

        guard advertisesOsmo || looksLikeOsmo(name) else { return }

        let device = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: name.isEmpty ? "Unknown" : name,
            rssi: RSSI.intValue
        )
        discovered[device.id] = device
        emitDiscovered()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let dev = DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? "Unknown",
            rssi: 0
        )
        delegate?.bleConnected(dev)
        delegate?.bleLog("Connected. Discovering services…")
        peripheral.discoverServices([.osmoService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        delegate?.bleDisconnected(error)
        delegate?.bleLog("Connect failed: \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        charFFF3 = nil; charFFF4 = nil; charFFF5 = nil
        parser.reset()
        delegate?.bleDisconnected(error)
        delegate?.bleLog("Disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            delegate?.bleLog("discoverServices error: \(error.localizedDescription)")
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == .osmoService }) else {
            delegate?.bleLog("Service FFF0 not found")
            return
        }
        peripheral.discoverCharacteristics(
            [.charFFF3, .charFFF4, .charFFF5],
            for: svc
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            delegate?.bleLog("discoverChars error: \(error.localizedDescription)")
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
        delegate?.bleLog("Characteristics: FFF3=\(charFFF3 != nil), FFF4=\(charFFF4 != nil), FFF5=\(charFFF5 != nil)")
        // Subscribe to notifications on every notify-capable characteristic.
        // Different DJI devices push DUML on different ones (Pocket 3 → FFF4,
        // some firmwares → FFF5).
        for c in [charFFF3, charFFF4, charFFF5].compactMap({ $0 }) {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        delegate?.bleReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            delegate?.bleLog("notify(\(characteristic.uuid)) error: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let chunk = [UInt8](data)
        let frames = parser.append(chunk)
        for f in frames {
            delegate?.bleReceived(f)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            delegate?.bleLog("write(\(characteristic.uuid)) error: \(error.localizedDescription)")
        }
    }
}

private extension CBManagerState {
    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "?"
        }
    }
}
