#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth

/// Un servizio seriale BLE: caratteristica TX (notify verso il telefono) e RX facoltativa (scritture dal telefono).
struct SerialProfile {
    let label: String
    let service: CBUUID
    let tx: CBUUID
    let rx: CBUUID?   // nil = TX e RX coincidono (stile HM-10)

    /// Nordic UART Service (UUID standard Nordic Semiconductor).
    static let nus = SerialProfile(label: "Nordic UART",
        service: CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        tx: CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
        rx: CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"))

    /// Seriale "HM-10 / TI CC254x": servizio FFE0, caratteristica unica FFE1.
    static let hm10 = SerialProfile(label: "HM-10 FFE0",
        service: CBUUID(string: "FFE0"), tx: CBUUID(string: "FFE1"), rx: nil)
}

/// Il Mac si annuncia come periferica BLE e invia NMEA in notify su tutti i profili attivi.
final class BLEPeripheral: NSObject, NMEAOutput, CBPeripheralManagerDelegate {
    let name: String
    let profiles: [SerialProfile]
    private var manager: CBPeripheralManager!
    private var txChars: [CBMutableCharacteristic] = []
    private var subscribers: [CBUUID: [CBCentral]] = [:]   // per caratteristica TX
    private var queue: [(Data, CBMutableCharacteristic)] = []
    private let maxQueue = 400
    private var dropped = 0
    private var lastChunk = Data()
    private var sent = 0
    private var lastStatus = Date()

    init(name: String, profiles: [SerialProfile]) {
        self.name = name; self.profiles = profiles
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    // MARK: Stato Bluetooth

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            Log.ble("Bluetooth acceso")
            setup()
        case .poweredOff: Log.error("Bluetooth spento: accenderlo in Impostazioni di Sistema")
        case .unauthorized:
            Log.error("Permesso Bluetooth negato: Impostazioni di Sistema > Privacy e sicurezza > Bluetooth, abilitare il Terminale (o l'app da cui si avvia)")
        case .unsupported: Log.error("Questo Mac non supporta la modalità periferica BLE")
        default: Log.ble("Stato Bluetooth: \(p.state.rawValue)")
        }
    }

    private func setup() {
        manager.removeAllServices()
        txChars = []
        for prof in profiles {
            let service = CBMutableService(type: prof.service, primary: true)
            var chars: [CBMutableCharacteristic] = []
            if let rx = prof.rx {
                let tx = CBMutableCharacteristic(type: prof.tx, properties: [.notify, .read], value: nil, permissions: [.readable])
                let rxc = CBMutableCharacteristic(type: rx, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
                chars = [tx, rxc]; txChars.append(tx)
            } else {
                let c = CBMutableCharacteristic(type: prof.tx, properties: [.notify, .read, .write, .writeWithoutResponse],
                                                value: nil, permissions: [.readable, .writeable])
                chars = [c]; txChars.append(c)
            }
            service.characteristics = chars
            manager.add(service)
            Log.ble("Servizio \(prof.label): \(prof.service.uuidString) (TX \(prof.tx.uuidString)\(prof.rx.map { ", RX " + $0.uuidString } ?? ""))")
        }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: profiles.map { $0.service },
        ])
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error { Log.error("Aggiunta servizio \(service.uuid.uuidString) fallita: \(e.localizedDescription)") }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let e = error { Log.error("Annuncio fallito: \(e.localizedDescription)") }
        else { Log.ble("Annuncio attivo come \"\(name)\": aprire SeeYou Navigator e cercare il dispositivo") }
    }

    // MARK: Telefono collegato

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        subscribers[c.uuid, default: []].append(central)
        Log.ble("CONNESSO: \(central.identifier.uuidString.prefix(8)) iscritto a \(c.uuid.uuidString) (max \(central.maximumUpdateValueLength) byte per pacchetto)")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        subscribers[c.uuid]?.removeAll { $0.identifier == central.identifier }
        Log.ble("Disiscritto: \(central.identifier.uuidString.prefix(8)) da \(c.uuid.uuidString)")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        Log.ble("Lettura da \(req.central.identifier.uuidString.prefix(8)) su \(req.characteristic.uuid.uuidString)")
        guard req.offset <= lastChunk.count else { p.respond(to: req, withResult: .invalidOffset); return }
        req.value = lastChunk.subdata(in: req.offset..<lastChunk.count)
        p.respond(to: req, withResult: .success)
    }

    /// Le scritture del telefono vengono solo registrate: possono rivelare cosa si aspetta l'app.
    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite reqs: [CBATTRequest]) {
        for r in reqs {
            let v = r.value ?? Data()
            let txt = String(data: v, encoding: .ascii)?.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") ?? ""
            let hex = v.map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.ble("SCRITTURA dal telefono su \(r.characteristic.uuid.uuidString): \"\(txt)\" [\(hex)]")
        }
        if let first = reqs.first { p.respond(to: first, withResult: .success) }
    }

    // MARK: Invio

    func send(_ sentence: String) {
        guard let data = sentence.data(using: .ascii) else { return }
        for c in txChars {
            let subs = subscribers[c.uuid] ?? []
            guard !subs.isEmpty else { continue }
            let mtu = max(20, subs.map { $0.maximumUpdateValueLength }.min() ?? 20)
            var i = 0
            while i < data.count {
                let end = min(i + mtu, data.count)
                queue.append((data.subdata(in: i..<end), c))
                i = end
            }
        }
        if queue.count > maxQueue {   // il telefono non sta al passo: scarta i dati più vecchi
            let n = queue.count - maxQueue
            queue.removeFirst(n); dropped += n
        }
        flush()
        if Date().timeIntervalSince(lastStatus) >= 10 {
            lastStatus = Date()
            let n = subscribers.values.reduce(0) { $0 + $1.count }
            Log.ble("Iscrizioni attive: \(n), pacchetti inviati: \(sent), scartati: \(dropped)")
        }
    }

    private func flush() {
        while let item = queue.first {
            let (chunk, c) = item
            guard manager.updateValue(chunk, for: c, onSubscribedCentrals: nil) else { return }  // riprova in isReady
            queue.removeFirst()
            lastChunk = chunk; sent += 1
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { flush() }
}
#endif
