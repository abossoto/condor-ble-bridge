import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
// Su Linux Glibc non espone queste funzioni a Swift: le dichiariamo (servono solo per i test).
@_silgen_name("posix_openpt") func posix_openpt(_ flags: Int32) -> Int32
@_silgen_name("grantpt") func grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt") func unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname") func ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#endif

/// Dove finiscono le frasi NMEA (BLE oppure stdout).
protocol NMEAOutput: AnyObject {
    func send(_ sentence: String)
}

/// Stampa le frasi a video (modalità --no-ble e test).
final class StdoutOutput: NMEAOutput {
    func send(_ sentence: String) {
        print(sentence.trimmingCharacters(in: .newlines)); fflush(stdout)
    }
}

// MARK: - Sorgente finta

/// Volo simulato: rotta costante, quota che oscilla, frasi GPRMC + GPGGA + LXWP0 a 1 Hz.
final class FakeSource {
    let output: NMEAOutput
    var lat: Double, lon: Double
    let speedKmh: Double, course: Double
    let baseAlt: Double
    private var t = 0.0
    private var timer: DispatchSourceTimer?

    init(output: NMEAOutput, lat: Double, lon: Double, speedKmh: Double, course: Double, alt: Double) {
        self.output = output; self.lat = lat; self.lon = lon
        self.speedKmh = speedKmh; self.course = course; self.baseAlt = alt
    }

    func start() {
        Log.info(String(format: "Sorgente finta: partenza %.5f, %.5f, %.0f km/h, rotta %.0f°, quota %.0f m",
                        lat, lon, speedKmh, course, baseAlt))
        let tm = DispatchSource.makeTimerSource(queue: .main)
        tm.schedule(deadline: .now(), repeating: 1.0)
        tm.setEventHandler { [weak self] in self?.tick() }
        tm.resume(); timer = tm
    }

    /// Un passo di 1 s: avanza la posizione e invia le tre frasi.
    func tick(now: Date = Date()) {
        let dist = speedKmh / 3.6               // metri in 1 s
        let r = course * .pi / 180
        lat += dist * cos(r) / 111_320
        lon += dist * sin(r) / (111_320 * cos(lat * .pi / 180))
        t += 1
        let alt = baseAlt + 150 * sin(t / 30)   // ciclo di circa 3 minuti
        let vario = 150.0 / 30 * cos(t / 30)    // derivata della quota, m/s
        for s in [NMEA.gprmc(date: now, lat: lat, lon: lon, speedKmh: speedKmh, courseDeg: course),
                  NMEA.gpgga(date: now, lat: lat, lon: lon, altM: alt),
                  NMEA.lxwp0(iasKmh: speedKmh, baroAltM: alt, varioMs: vario, headingDeg: course)] {
            Log.data(s.trimmingCharacters(in: .newlines))
            output.send(s)
        }
    }
}

// MARK: - Porta seriale virtuale (pty) per Condor sotto Wine

/// Crea uno pseudo-terminale: Condor (via Wine) scrive sul lato "slave" come se fosse COM1,
/// noi leggiamo dal lato "master", controlliamo il checksum e inoltriamo.
final class PTYSource {
    let output: NMEAOutput
    let linkPath: String?
    let checkChecksum: Bool
    var geoidSeparation: String?   // se impostato, riempie il campo geoide di $GPGGA
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var assembler = LineAssembler()
    private(set) var slavePath = ""
    private var stats = (ok: 0, bad: 0)
    private var lastStatus = Date()
    private var counts: [String: Int] = [:]

    init(output: NMEAOutput, linkPath: String?, checkChecksum: Bool) {
        self.output = output; self.linkPath = linkPath; self.checkChecksum = checkChecksum
    }

    func start() throws {
        masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0, grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
              let name = ptsname(masterFD) else {
            throw BridgeError("impossibile creare lo pseudo-terminale: \(String(cString: strerror(errno)))")
        }
        slavePath = String(cString: name)
        // Teniamo aperto anche lo slave: senza nessuno collegato, su macOS la lettura dal master
        // restituirebbe errore. Modalità raw: niente eco verso Condor, niente conversioni.
        slaveFD = open(slavePath, O_RDWR | O_NOCTTY)
        if slaveFD >= 0 {
            var tio = termios()
            if tcgetattr(slaveFD, &tio) == 0 { cfmakeraw(&tio); tcsetattr(slaveFD, TCSANOW, &tio) }
        }
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        Log.info("Porta seriale virtuale creata: \(slavePath)")

        if let link = linkPath { try makeLink(link) }

        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .main)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume(); readSource = src
        Log.info("In attesa di NMEA da Condor (Setup > Options > NMEA Output sulla porta COM collegata)…")
    }

    private func makeLink(_ link: String) throws {
        let fm = FileManager.default
        let path = (link as NSString).expandingTildeInPath
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            // Sostituiamo solo un collegamento simbolico, mai un file vero.
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw BridgeError("\(path) esiste e non è un collegamento simbolico: non lo tocco")
            }
            let old = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?"
            try fm.removeItem(atPath: path)
            Log.info("Collegamento \(path) sostituito (prima puntava a \(old))")
        } else if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
            try fm.removeItem(atPath: path)   // collegamento rotto
        }
        try fm.createSymbolicLink(atPath: path, withDestinationPath: slavePath)
        Log.info("Collegamento creato: \(path) -> \(slavePath)")
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(masterFD, &buf, buf.count)
        guard n > 0 else { return }
        for line in assembler.feed(Data(buf[0..<n])) { handle(line) }
        if Date().timeIntervalSince(lastStatus) >= 10 { status() }
    }

    func handle(_ line: String) {
        let v = NMEA.validate(line)
        if checkChecksum && v != .ok {
            stats.bad += 1
            Log.warn("Riga scartata (\(v)): \(line)")
            return
        }
        stats.ok += 1
        let type = String(line.dropFirst().prefix(while: { $0 != "," }))
        if counts[type] == nil { Log.info("Nuovo tipo di frase da Condor: $\(type)") }
        counts[type, default: 0] += 1
        let out = geoidSeparation.map { NMEA.setGeoidSeparation(line, meters: $0) } ?? line
        Log.data(out)
        output.send(out + "\r\n")
    }

    private func status() {
        lastStatus = Date()
        let tipi = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Log.info("Da Condor: \(stats.ok) frasi valide, \(stats.bad) scartate [\(tipi)]")
    }

    func stop() {
        if let link = linkPath {
            let path = (link as NSString).expandingTildeInPath
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == slavePath {
                try? FileManager.default.removeItem(atPath: path)
                Log.info("Collegamento \(path) rimosso")
            }
        }
    }
}

// MARK: - UDP di Condor

/// Riceve i pacchetti UDP di Condor (UDP.ini). Se `output` è nil, si limita a stamparli (diagnostica).
final class UDPSource {
    let port: UInt16
    let output: NMEAOutput?
    let dumpPath: String?
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var dumpHandle: FileHandle?
    private var packets = 0
    private var lastSend = Date.distantPast
    private var lastStatus = Date()
    private var shownKeys = false

    init(port: UInt16, output: NMEAOutput?, dumpPath: String?) {
        self.port = port; self.output = output; self.dumpPath = dumpPath
    }

    func start() throws {
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { throw BridgeError("socket UDP: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: 0)   // INADDR_ANY   // ascolta su tutte le interfacce
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw BridgeError("porta UDP \(port) non disponibile: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        if let p = dumpPath {
            let path = (p as NSString).expandingTildeInPath
            _ = FileManager.default.createFile(atPath: path, contents: nil)
            dumpHandle = FileHandle(forWritingAtPath: path)
            Log.info("Pacchetti grezzi salvati in \(path)")
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.receive() }
        src.resume(); readSource = src
        Log.info("In ascolto UDP sulla porta \(port) (in UDP.ini: Enabled=1, Port=\(port))")
        if output != nil {
            Log.warn("Secondo la documentazione l'UDP di Condor non contiene la posizione: invio solo $LXWP0 (velocità, quota, vario). Per la mappa usare 'serial'.")
        }
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return }
        packets += 1
        let data = Data(buf[0..<n])
        if let h = dumpHandle {
            h.write("--- \(ISO8601DateFormatter().string(from: Date())) (\(n) byte)\n".data(using: .utf8)!)
            h.write(data); h.write("\n".data(using: .utf8)!)
        }
        guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) else { return }
        let pkt = CondorUDPPacket(text)

        if output == nil {   // udp-log: stampa tutto
            Log.info("Pacchetto #\(packets) (\(n) byte):\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        if !shownKeys {
            shownKeys = true
            Log.info("Primo pacchetto UDP, chiavi: \(pkt.raw.keys.sorted().joined(separator: ", "))")
        }
        if Date().timeIntervalSince(lastStatus) >= 10 {
            lastStatus = Date()
            Log.info("UDP: \(packets) pacchetti ricevuti")
        }
        // Al massimo 2 frasi al secondo verso il telefono.
        guard Date().timeIntervalSince(lastSend) >= 0.5 else { return }
        guard let s = pkt.toLXWP0() else {
            Log.warn("Pacchetto senza 'altitude', ignorato"); return
        }
        lastSend = Date()
        Log.data(s.trimmingCharacters(in: .newlines))
        output?.send(s)
    }
}

struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
