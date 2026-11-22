import Foundation

/// Log leggibile su stdout: "HH:mm:ss.SSS [LIVELLO] messaggio".
enum Log {
    static var verbose = false
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let lock = NSLock()

    private static func emit(_ level: String, _ msg: String) {
        lock.lock(); defer { lock.unlock() }
        print("\(fmt.string(from: Date())) [\(level)] \(msg)")
        fflush(stdout)
    }
    static func info(_ m: String)  { emit("INFO ", m) }
    static func warn(_ m: String)  { emit("ATTENZIONE", m) }
    static func error(_ m: String) { emit("ERRORE", m) }
    static func ble(_ m: String)   { emit("BLE  ", m) }
    static func data(_ m: String)  { if verbose { emit("DATI ", m) } }
}
