import Foundation

public enum Verifier {
    /// Relee el archivo desde disco y compara tamaño y SHA-256 con lo esperado.
    public static func verify(file url: URL, expectedSHA256: String, expectedSize: Int64) throws -> Bool {
        let (digest, size) = try FileHasher.sha256(of: url)
        return size == expectedSize && digest == expectedSHA256
    }

    /// Re-verifica todos los archivos de un elemento registrado en el manifiesto.
    public static func verify(record: AssetRecord, root: URL) -> Bool {
        guard !record.resources.isEmpty else { return false }
        for r in record.resources {
            let url = root.appendingPathComponent(r.relativePath)
            guard (try? verify(file: url, expectedSHA256: r.sha256, expectedSize: r.size)) == true else {
                return false
            }
        }
        return true
    }
}
