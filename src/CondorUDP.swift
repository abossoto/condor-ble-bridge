import Foundation

/// Pacchetto UDP di Condor: testo ASCII "chiave=valore" (separati da a capo o spazi).
/// Formato ricavato da forum e dalla tabella del manuale citata in XCSoar issue #2488;
/// NON verificato su pacchetti reali di Condor 3.1.0: usare `udp-log` per controllarlo.
struct CondorUDPPacket {
    var values: [String: Double] = [:]
    var raw: [String: String] = [:]

    init(_ text: String) {
        let tokens = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" || $0 == ";" })
        for tok in tokens {
            guard let eq = tok.firstIndex(of: "=") else { continue }
            let k = tok[..<eq].lowercased()
            let v = String(tok[tok.index(after: eq)...])
            raw[k] = v
            if let d = Double(v) { values[k] = d }
        }
    }

    var isEmpty: Bool { raw.isEmpty }

    /// Unità ipotizzate (SI, secondo il supporto Condor sul forum): airspeed m/s, altitude m, vario m/s.
    /// Il pacchetto non contiene lat/lon: non si può produrre $GPRMC/$GPGGA.
    func toLXWP0() -> String? {
        guard let altitude = values["altitude"] else { return nil }
        let ias = (values["airspeed"] ?? 0) * 3.6
        let vario = values["evario"] ?? values["vario"] ?? 0
        let heading = values["compass"]   // unità non verificata (gradi?)
        return NMEA.lxwp0(iasKmh: ias, baroAltM: altitude, varioMs: vario, headingDeg: heading)
    }
}
