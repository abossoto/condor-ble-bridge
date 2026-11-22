import Foundation

/// Funzioni NMEA 0183: checksum, validazione, costruzione frasi.
enum NMEA {
    /// XOR di tutti i caratteri tra '$' e '*' (esclusi).
    static func checksum(_ body: String) -> UInt8 {
        var cs: UInt8 = 0
        for b in body.utf8 { cs ^= b }
        return cs
    }

    /// Da "GPRMC,..." a "$GPRMC,...*hh\r\n".
    static func sentence(_ body: String) -> String {
        "$" + body + "*" + String(format: "%02X", checksum(body)) + "\r\n"
    }

    enum Validation: Equatable { case ok, noDollar, noChecksum, badChecksum(expected: String, found: String) }

    /// Valida una riga NMEA (senza CR/LF finali).
    static func validate(_ line: String) -> Validation {
        guard line.hasPrefix("$") else { return .noDollar }
        guard let star = line.lastIndex(of: "*") else { return .noChecksum }
        let body = String(line[line.index(after: line.startIndex)..<star])
        let found = String(line[line.index(after: star)...]).uppercased()
        let expected = String(format: "%02X", checksum(body))
        return found == expected ? .ok : .badChecksum(expected: expected, found: found)
    }

    /// Riempie la separazione del geoide (campi 11-12) di una $GPGGA e ricalcola il checksum.
    /// Condor lascia il campo vuoto: alcune app allora correggono la quota con un geoide proprio.
    /// Le altre frasi vengono restituite invariate.
    static func setGeoidSeparation(_ line: String, meters: String) -> String {
        guard line.hasPrefix("$GPGGA,"), let star = line.lastIndex(of: "*") else { return line }
        var fields = line[line.index(after: line.startIndex)..<star].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 13 else { return line }
        fields[11] = meters
        fields[12] = "M"
        return sentence(fields.joined(separator: ",")).trimmingCharacters(in: .newlines)
    }

    // MARK: - Costruzione frasi

    /// Gradi decimali -> "ddmm.mmmm" / "dddmm.mmmm" + emisfero.
    static func coord(_ deg: Double, isLat: Bool) -> (String, String) {
        let hemi = isLat ? (deg >= 0 ? "N" : "S") : (deg >= 0 ? "E" : "W")
        let a = abs(deg)
        var d = Int(a)
        var m = (a - Double(d)) * 60
        if (m * 10000).rounded() >= 600000 { d += 1; m = 0 }   // evita "60.0000"
        let s = isLat ? String(format: "%02d%07.4f", d, m) : String(format: "%03d%07.4f", d, m)
        return (s, hemi)
    }

    static func utcParts(_ date: Date) -> (time: String, date: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let cs = (c.nanosecond ?? 0) / 10_000_000
        let t = String(format: "%02d%02d%02d.%02d", c.hour!, c.minute!, c.second!, cs)
        let d = String(format: "%02d%02d%02d", c.day!, c.month!, c.year! % 100)
        return (t, d)
    }

    /// $GPRMC: posizione, velocità al suolo (nodi), rotta vera.
    static func gprmc(date: Date, lat: Double, lon: Double, speedKmh: Double, courseDeg: Double) -> String {
        let (t, d) = utcParts(date)
        let (la, ns) = coord(lat, isLat: true)
        let (lo, ew) = coord(lon, isLat: false)
        let knots = speedKmh / 1.852
        return sentence(String(format: "GPRMC,%@,A,%@,%@,%@,%@,%.1f,%.1f,%@,,,A",
                               t, la, ns, lo, ew, knots, courseDeg, d))
    }

    /// $GPGGA: posizione, fix, satelliti, quota GPS (m).
    static func gpgga(date: Date, lat: Double, lon: Double, altM: Double) -> String {
        let (t, _) = utcParts(date)
        let (la, ns) = coord(lat, isLat: true)
        let (lo, ew) = coord(lon, isLat: false)
        return sentence(String(format: "GPGGA,%@,%@,%@,%@,%@,1,12,0.8,%.1f,M,0.0,M,,",
                               t, la, ns, lo, ew, altM))
    }

    /// $LXWP0 (protocollo LX): IAS km/h, quota baro m, vario m/s, prua, vento.
    /// Campi: logger,IAS,quota,vario1..vario6,prua,dir.vento,vel.vento
    static func lxwp0(iasKmh: Double, baroAltM: Double, varioMs: Double,
                      headingDeg: Double?, windDirDeg: Double? = nil, windKmh: Double? = nil) -> String {
        func f(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "" }
        return sentence("LXWP0,Y,\(f(iasKmh, "%.1f")),\(f(baroAltM, "%.1f")),\(f(varioMs, "%.2f")),,,,,,\(f(headingDeg, "%.0f")),\(f(windDirDeg, "%.0f")),\(f(windKmh, "%.1f"))")
    }
}

/// Ricompone righe complete da un flusso di byte (separatori CR e/o LF).
struct LineAssembler {
    private var buffer = Data()
    private let maxLen = 512

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[buffer.index(after: idx)...])
            if let s = String(data: lineData, encoding: .ascii)?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
                lines.append(s)
            }
        }
        if buffer.count > maxLen { buffer.removeAll() }   // spazzatura senza fine riga
        return lines
    }
}
