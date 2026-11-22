import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let usage = """
condor-ble-bridge — Condor 3 → BLE → SeeYou Navigator

USO
  condor-ble-bridge fake     [opzioni]   NMEA finto via BLE (test del collegamento)
  condor-ble-bridge serial   [opzioni]   porta seriale virtuale per Condor/Wine → BLE
  condor-ble-bridge udp      [opzioni]   UDP di Condor → $LXWP0 via BLE (senza posizione)
  condor-ble-bridge udp-log  [opzioni]   stampa i pacchetti UDP di Condor (diagnostica, niente BLE)
  condor-ble-bridge selftest             controlli interni (checksum, frasi, parser UDP)

OPZIONI BLE
  --name NOME          nome annunciato (predefinito: Condor3)
  --profile P          nus | hm10 | both | custom  (predefinito: nus)
  --service UUID       con --profile custom: UUID del servizio
  --tx UUID            con --profile custom: caratteristica notify verso il telefono
  --rx UUID            con --profile custom: caratteristica di scrittura (facoltativa)
  --no-ble             niente Bluetooth: stampa le frasi a video

OPZIONI fake
  --lat GRADI --lon GRADI   partenza (predefinito 45.07 7.69)
  --speed KMH               (predefinito 100)   --course GRADI (predefinito 90)
  --alt METRI               (predefinito 1500)

OPZIONI serial
  --link PERCORSO      crea un collegamento simbolico alla porta (es. .../dosdevices/com1)
  --no-checksum        inoltra anche le righe con checksum errato
  --geoide METRI       riempie la separazione del geoide in $GPGGA (Condor la lascia vuota), es. 0

OPZIONI udp / udp-log
  --port N             porta UDP (predefinito 55278)
  --dump FILE          salva i pacchetti grezzi su file

GENERALI
  -v, --verbose        mostra ogni frase inviata
"""

// MARK: - Argomenti

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, !["-h", "--help", "help"].contains(command) else { print(usage); exit(0) }
args.removeFirst()

var opts: [String: String] = [:]
var flags = Set<String>()
let flagNames: Set = ["--no-ble", "--no-checksum", "-v", "--verbose"]
var i = 0
while i < args.count {
    let a = args[i]
    if flagNames.contains(a) { flags.insert(a); i += 1; continue }
    guard a.hasPrefix("--"), i + 1 < args.count else { print("Argomento non valido: \(a)\n\n\(usage)"); exit(2) }
    opts[a] = args[i + 1]; i += 2
}
Log.verbose = flags.contains("-v") || flags.contains("--verbose")
func dbl(_ k: String, _ d: Double) -> Double {
    guard let s = opts[k] else { return d }
    guard let v = Double(s) else { print("Valore non numerico per \(k): \(s)"); exit(2) }
    return v
}

// MARK: - Selftest

func selftest() -> Never {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "OK    " : "FALLITO ") + name); if !ok { fails += 1 } }

    // Esempio classico NMEA con checksum noto (*47).
    check("checksum GPGGA di riferimento",
          NMEA.validate("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47") == .ok)
    check("checksum errato rilevato",
          NMEA.validate("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*48") != .ok)
    check("coordinate lat", NMEA.coord(45.5, isLat: true) == ("4530.0000", "N"))
    check("coordinate lon ovest", NMEA.coord(-7.25, isLat: false) == ("00715.0000", "W"))
    check("coordinate arrotondamento 60'", NMEA.coord(44.999999999, isLat: true) == ("4500.0000", "N"))

    let d = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
    let rmc = NMEA.gprmc(date: d, lat: 45.07, lon: 7.69, speedKmh: 100, courseDeg: 90)
    check("GPRMC valida: \(rmc.trimmingCharacters(in: .newlines))",
          NMEA.validate(rmc.trimmingCharacters(in: .newlines)) == .ok && rmc.contains("221320.00") && rmc.contains("141123"))
    let gga = NMEA.gpgga(date: d, lat: 45.07, lon: 7.69, altM: 1500)
    check("GPGGA valida: \(gga.trimmingCharacters(in: .newlines))", NMEA.validate(gga.trimmingCharacters(in: .newlines)) == .ok)
    let lx = NMEA.lxwp0(iasKmh: 100, baroAltM: 1500, varioMs: 1.25, headingDeg: 90)
    check("LXWP0 valida: \(lx.trimmingCharacters(in: .newlines))", NMEA.validate(lx.trimmingCharacters(in: .newlines)) == .ok)

    // Frase reale di Condor 3.1.0 (registro del 22/11/2026): campo geoide vuoto e un campo in più.
    let condorGGA = "$GPGGA,123322.104,4522.7145,N,00732.1565,E,1,12,10,1899.6,M,,,,,0000*31"
    check("GGA di Condor valida", NMEA.validate(condorGGA) == .ok)
    let geo = NMEA.setGeoidSeparation(condorGGA, meters: "0.0")
    check("geoide riempito: \(geo)", geo.hasPrefix("$GPGGA,123322.104,4522.7145,N,00732.1565,E,1,12,10,1899.6,M,0.0,M,,,0000*")
          && NMEA.validate(geo) == .ok)
    check("geoide: altre frasi invariate", NMEA.setGeoidSeparation("$LXWP0,Y,1*00", meters: "0") == "$LXWP0,Y,1*00")

    var asm = LineAssembler()
    let l1 = asm.feed("$A*41\r\n$B".data(using: .ascii)!)
    let l2 = asm.feed("*42\n".data(using: .ascii)!)
    check("ricomposizione righe spezzate", l1 == ["$A*41"] && l2 == ["$B*42"])

    let pkt = CondorUDPPacket("time=13.06\nairspeed=34.18\naltitude=1813.67\nvario=1.80\n")
    check("parser UDP (a capo)", pkt.values["airspeed"] == 34.18 && pkt.values["altitude"] == 1813.67)
    let pkt2 = CondorUDPPacket("time=13.06 airspeed=34.18 altitude=1813.67 vario=1.80")
    check("parser UDP (spazi)", pkt2.values["vario"] == 1.80)
    let lxu = pkt.toLXWP0() ?? ""
    check("UDP -> LXWP0: \(lxu.trimmingCharacters(in: .newlines))", lxu.contains(",123.0,1813.7,1.80,") && NMEA.validate(lxu.trimmingCharacters(in: .newlines)) == .ok)

    print(fails == 0 ? "\nTutti i controlli superati." : "\n\(fails) controlli falliti.")
    exit(fails == 0 ? 0 : 1)
}

if command == "selftest" { selftest() }

// MARK: - Uscita

func makeOutput() -> NMEAOutput {
    if flags.contains("--no-ble") {
        Log.info("Modalità --no-ble: le frasi vengono stampate a video")
        return StdoutOutput()
    }
    #if canImport(CoreBluetooth)
    let name = opts["--name"] ?? "Condor3"
    var profiles: [SerialProfile]
    switch opts["--profile"] ?? "nus" {
    case "nus": profiles = [.nus]
    case "hm10": profiles = [.hm10]
    case "both": profiles = [.nus, .hm10]
    case "custom":
        guard let s = opts["--service"], let t = opts["--tx"] else {
            print("--profile custom richiede --service e --tx"); exit(2)
        }
        profiles = [SerialProfile(label: "personalizzato", service: CBUUID(string: s), tx: CBUUID(string: t),
                                  rx: opts["--rx"].map { CBUUID(string: $0) })]
    case let p: print("Profilo sconosciuto: \(p)"); exit(2)
    }
    return BLEPeripheral(name: name, profiles: profiles)
    #else
    Log.error("CoreBluetooth non disponibile su questo sistema: usare --no-ble")
    exit(1)
    #endif
}

// MARK: - Avvio

var keepAlive: [AnyObject] = []
var cleanup: (() -> Void)?

// Ctrl-C: pulizia e uscita.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { Log.info("Chiusura…"); cleanup?(); exit(0) }
sigint.resume()

do {
    switch command {
    case "fake":
        let out = makeOutput()
        let src = FakeSource(output: out, lat: dbl("--lat", 45.07), lon: dbl("--lon", 7.69),
                             speedKmh: dbl("--speed", 100), course: dbl("--course", 90), alt: dbl("--alt", 1500))
        src.start(); keepAlive = [out, src]
    case "serial":
        let out = makeOutput()
        let src = PTYSource(output: out, linkPath: opts["--link"], checkChecksum: !flags.contains("--no-checksum"))
        if let g = opts["--geoide"] {
            guard Double(g) != nil else { print("Valore non numerico per --geoide: \(g)"); exit(2) }
            src.geoidSeparation = g
            Log.info("Separazione del geoide in $GPGGA impostata a \(g) m")
        }
        try src.start(); keepAlive = [out, src]
        cleanup = { src.stop() }
    case "udp", "udp-log":
        let port = UInt16(dbl("--port", 55278))
        let out: NMEAOutput? = command == "udp" ? makeOutput() : nil
        let src = UDPSource(port: port, output: out, dumpPath: opts["--dump"])
        try src.start(); keepAlive = [src] + (out.map { [$0] } ?? [])
    default:
        print("Comando sconosciuto: \(command)\n\n\(usage)"); exit(2)
    }
} catch {
    Log.error("\(error)"); exit(1)
}

Log.info("Avviato. Ctrl-C per uscire.")
dispatchMain()
