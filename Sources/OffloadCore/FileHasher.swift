import CryptoKit
import Foundation

public enum FileHasher {
    /// Calcula el SHA-256 leyendo el archivo desde disco.
    /// `F_NOCACHE` evita que la lectura pase por la caché de páginas; combinado con que
    /// la escritura también usa `F_NOCACHE`, la verificación lee lo que realmente quedó en el disco.
    public static func sha256(of url: URL, bypassCache: Bool = true) throws -> (digest: String, size: Int64) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if bypassCache { _ = fcntl(fd, F_NOCACHE, 1) }

        let bufferSize = 4 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let n = read(fd, buffer, bufferSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            // Permite detener rápido la verificación de archivos grandes.
            if Task.isCancelled { throw CancellationError() }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            total += Int64(n)
        }
        return (hasher.finalize().hexString, total)
    }
}

extension Digest {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
