import CryptoKit
import Foundation
import Photos

public struct ExportedFile: Sendable {
    public var url: URL
    public var size: Int64
    /// SHA-256 de los bytes tal como los entregó Fotos (calculado en streaming).
    public var sha256: String
}

/// Escribe los bytes recibidos y calcula el hash a la vez.
private final class StreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hasher = SHA256()
    private var size: Int64 = 0
    private var failure: Error?
    var onFailure: (() -> Void)?

    init(handle: FileHandle) { self.handle = handle }

    func consume(_ data: Data) {
        let failedNow: Bool = lock.withLock {
            guard failure == nil else { return false }
            do {
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                size += Int64(data.count)
                return false
            } catch {
                failure = error
                return true
            }
        }
        if failedNow { onFailure?() }
    }

    func result() throws -> (String, Int64) {
        try lock.withLock {
            if let failure { throw failure }
            return (hasher.finalize().hexString, size)
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false

    func set(_ newID: PHAssetResourceDataRequestID) {
        lock.withLock {
            id = newID
            if cancelled { PHAssetResourceManager.default().cancelDataRequest(newID) }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }
}

public enum ResourceExporter {
    /// Descarga (si hace falta, desde iCloud) el recurso original y lo escribe en `finalURL`.
    /// Escribe primero a un archivo temporal oculto, fuerza el vaciado a disco y luego renombra,
    /// para que nunca quede un archivo final a medias.
    public static func export(_ resource: PHAssetResource, to finalURL: URL) async throws -> ExportedFile {
        let fm = FileManager.default
        let tmp = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }

        do {
            let handle = try FileHandle(forWritingTo: tmp)
            // Sin caché: la verificación posterior leerá desde el disco físico.
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

            let writer = StreamWriter(handle: handle)
            let box = RequestBox()
            writer.onFailure = { box.cancel() }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true  // descarga el original de iCloud si no está local

            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        let id = PHAssetResourceManager.default().requestData(
                            for: resource, options: options,
                            dataReceivedHandler: { data in writer.consume(data) },
                            completionHandler: { error in
                                if let error { cont.resume(throwing: error) } else { cont.resume() }
                            })
                        box.set(id)
                    }
                } onCancel: {
                    box.cancel()
                }
            } catch {
                try? handle.close()
                // Prioriza el error de escritura (p. ej. disco lleno) sobre el de cancelación.
                _ = try writer.result()
                throw error
            }
            try Task.checkCancellation()

            let (digest, size) = try writer.result()
            // F_FULLFSYNC garantiza que los datos llegaron al medio físico; algunos formatos (exFAT) no lo soportan.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try handle.synchronize() }
            try handle.close()

            guard size > 0 else { throw OffloadError.emptyResource(resource.originalFilename) }
            try fm.moveItem(at: tmp, to: finalURL)
            return ExportedFile(url: finalURL, size: size, sha256: digest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
