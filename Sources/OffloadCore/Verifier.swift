import Foundation

public enum Verifier {
    /// Relee el archivo desde disco y compara tamaño y SHA-256 con lo esperado.
    public static func verify(file url: URL, expectedSHA256: String, expectedSize: Int64) throws -> Bool {
        let (digest, size) = try FileHasher.sha256(of: url)
        return size == expectedSize && digest == expectedSHA256
    }

    /// Re-verifica todos los archivos de un elemento registrado en el manifiesto.
    /// Lanza `CancellationError` si se detiene el proceso; cualquier otro fallo cuenta como «no coincide».
    public static func verify(record: AssetRecord, root: URL) throws -> Bool {
        guard !record.resources.isEmpty else { return false }
        for r in record.resources {
            // El registro vive en el disco externo y podría estar manipulado: la ruta debe quedar
            // dentro de la carpeta destino y apuntar a un archivo normal.
            guard let url = PathSafety.resolve(r.relativePath, in: root), PathSafety.isRegularFile(url) else {
                return false
            }
            do {
                guard try verify(file: url, expectedSHA256: r.sha256, expectedSize: r.size) else { return false }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return false
            }
        }
        return true
    }
}
