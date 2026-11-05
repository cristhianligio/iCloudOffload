import Foundation

/// Registro de auditoría en el disco externo: `<destino>/.icloud-offload/manifest.jsonl`.
/// Una línea JSON por evento (verificado / borrado); la última línea de cada elemento manda.
/// Permite reanudar: lo ya copiado y verificado no se vuelve a copiar.
public actor Manifest {
    public nonisolated let url: URL
    private var records: [String: AssetRecord]
    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(directory: URL) throws {
        let dir = directory.appendingPathComponent(".icloud-offload", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.url = url
        self.records = try Manifest.load(url)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
    }

    static func load(_ url: URL) throws -> [String: AssetRecord] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [String: AssetRecord] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // Una línea truncada (p. ej. por desconexión del disco) se ignora.
            if let r = try? decoder.decode(AssetRecord.self, from: Data(line)) {
                out[r.localIdentifier] = r
            }
        }
        return out
    }

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".icloud-offload/manifest.jsonl")
    }

    /// Resumen rápido para la interfaz: elementos registrados y cuántos ya se borraron de iCloud.
    /// `nil` si todavía no existe un registro en esa carpeta.
    public static func summary(in directory: URL) -> (records: Int, deleted: Int)? {
        let url = fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path), let recs = try? load(url) else { return nil }
        return (recs.count, recs.values.filter { $0.deletedAt != nil }.count)
    }

    public func record(for id: String) -> AssetRecord? { records[id] }
    public var count: Int { records.count }

    public func append(_ record: AssetRecord) throws {
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line)
        try handle.synchronize()
        records[record.localIdentifier] = record
    }

    public func markDeleted(_ ids: [String], at date: Date = Date()) throws {
        for id in ids {
            guard var r = records[id] else { continue }
            r.deletedAt = date
            try append(r)
        }
    }

    deinit { try? handle.close() }
}
