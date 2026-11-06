import CryptoKit
import Foundation

/// Registro de auditoría en el disco externo: `<destino>/.icloud-offload/manifest.jsonl`.
/// Una línea JSON por evento (verificado / borrado); la última línea de cada elemento manda.
/// Permite reanudar: lo ya copiado y verificado no se vuelve a copiar.
///
/// Cada línea lleva una firma HMAC-SHA256 hecha con una clave guardada en el Llavero (`ManifestKey`).
/// Solo las líneas con firma válida son «de confianza»; el resto (registros de versiones anteriores,
/// líneas editadas o añadidas por otro programa) sirve para reanudar, pero nunca para autorizar un borrado
/// sin comprobar antes la copia contra iCloud.
public actor Manifest {
    public struct Entry: Sendable {
        public var record: AssetRecord
        /// La línea tenía una firma válida con la clave de este Mac.
        public var trusted: Bool
    }

    public nonisolated let url: URL
    /// Hay clave para firmar (si no, todo lo que se escriba quedará sin firma).
    public nonisolated let signing: Bool
    private var entries: [String: Entry]
    private let handle: FileHandle
    private let key: SymmetricKey?

    public init(directory: URL, key: SymmetricKey?) throws {
        let dir = directory.appendingPathComponent(".icloud-offload", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.url = url
        self.key = key
        self.signing = key != nil
        self.entries = try Manifest.load(url, key: key)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    /// Firma de un registro: HMAC de su JSON canónico (claves ordenadas, sin el campo `mac`).
    static func mac(for record: AssetRecord, key: SymmetricKey) throws -> String {
        var r = record
        r.mac = nil
        var data = Data("icloud-offload/manifest/v1\n".utf8)
        data.append(try encoder.encode(r))
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ url: URL, key: SymmetricKey?) throws -> [String: Entry] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [String: Entry] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // Una línea truncada (p. ej. por desconexión del disco) se ignora.
            guard var r = try? decoder.decode(AssetRecord.self, from: Data(line)) else { continue }
            var trusted = false
            if let key, let stored = r.mac, let expected = try? mac(for: r, key: key) {
                trusted = constantTimeEqual(stored, expected)
            }
            r.mac = nil
            out[r.localIdentifier] = Entry(record: r, trusted: trusted)
        }
        return out
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".icloud-offload/manifest.jsonl")
    }

    /// Resumen rápido para la interfaz: elementos registrados y cuántos ya se borraron de iCloud.
    /// `nil` si todavía no existe un registro en esa carpeta.
    public static func summary(in directory: URL) -> (records: Int, deleted: Int)? {
        let url = fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path), let entries = try? load(url, key: nil) else { return nil }
        return (entries.count, entries.values.filter { $0.record.deletedAt != nil }.count)
    }

    public func entry(for id: String) -> Entry? { entries[id] }
    public func record(for id: String) -> AssetRecord? { entries[id]?.record }
    public var count: Int { entries.count }

    /// Añade una línea firmada. Solo se debe llamar con registros que la app acaba de verificar ella misma.
    public func append(_ record: AssetRecord) throws {
        var r = record
        r.mac = nil
        var signed = r
        if let key { signed.mac = try Manifest.mac(for: r, key: key) }
        var line = try Manifest.encoder.encode(signed)
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line)
        try handle.synchronize()
        entries[r.localIdentifier] = Entry(record: r, trusted: key != nil)
    }

    public func markDeleted(_ ids: [String], at date: Date = Date()) throws {
        for id in ids {
            guard var r = entries[id]?.record else { continue }
            r.deletedAt = date
            try append(r)
        }
    }

    deinit { try? handle.close() }
}
