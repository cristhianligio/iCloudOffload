import CryptoKit
import Foundation
import Photos

public struct ExportedFile: Sendable {
    public var url: URL
    public var size: Int64
    /// SHA-256 de los bytes tal como los entregó Fotos (calculado en streaming).
    public var sha256: String
}

public struct ExportProgress: Sendable {
    /// Progreso de la descarga desde iCloud (solo si el original no estaba en el Mac).
    public var downloadFraction: Double?
    public var bytesWritten: Int64
    public var expectedBytes: Int64?

    /// Mejor estimación disponible de 0…1 para este recurso.
    public var fraction: Double? {
        var best: Double?
        if let d = downloadFraction { best = d }
        if let e = expectedBytes, e > 0 {
            let w = min(1, Double(bytesWritten) / Double(e))
            best = max(best ?? 0, w)
        }
        return best
    }
}

/// Escribe los bytes recibidos (si hay archivo), calcula el hash a la vez y lleva la cuenta del progreso.
private final class StreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private var hasher = SHA256()
    private var size: Int64 = 0
    private var failure: Error?
    private var downloadFraction: Double?
    private var lastReport = Date.distantPast
    private let expectedBytes: Int64?
    private let report: (@Sendable (ExportProgress) -> Void)?
    private let onNetworkProgress: (@Sendable () -> Void)?
    var onFailure: (() -> Void)?

    init(handle: FileHandle?, expectedBytes: Int64?,
         report: (@Sendable (ExportProgress) -> Void)?, onNetworkProgress: (@Sendable () -> Void)?) {
        self.handle = handle
        self.expectedBytes = expectedBytes
        self.report = report
        self.onNetworkProgress = onNetworkProgress
    }

    func consume(_ data: Data) {
        let failedNow: Bool = lock.withLock {
            guard failure == nil else { return false }
            do {
                try handle?.write(contentsOf: data)
                hasher.update(data: data)
                size += Int64(data.count)
                return false
            } catch {
                failure = error
                return true
            }
        }
        if failedNow { onFailure?() } else { onNetworkProgress?(); maybeReport() }
    }

    func downloadProgress(_ p: Double) {
        lock.withLock { downloadFraction = p }
        onNetworkProgress?()
        maybeReport()
    }

    /// Como mucho 5 avisos por segundo para no saturar la interfaz.
    private func maybeReport(force: Bool = false) {
        guard let report else { return }
        let snapshot: ExportProgress? = lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.2 else { return nil }
            lastReport = now
            return ExportProgress(downloadFraction: downloadFraction, bytesWritten: size, expectedBytes: expectedBytes)
        }
        if let snapshot { report(snapshot) }
    }

    func finalReport() { maybeReport(force: true) }

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
    /// Pide a Fotos los bytes del recurso original (descargándolo de iCloud si hace falta) y los pasa a `writer`.
    private static func request(_ resource: PHAssetResource, writer: StreamWriter, box: RequestBox) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // descarga el original de iCloud si no está local
        options.progressHandler = { p in writer.downloadProgress(p) }
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
    }

    /// SHA-256 y tamaño del original tal como lo entrega Fotos/iCloud, sin escribir nada en disco.
    /// Sirve para confirmar contra la fuente una copia anterior cuyo registro no es de confianza.
    public static func digest(
        of resource: PHAssetResource,
        progress: (@Sendable (ExportProgress) -> Void)? = nil,
        onNetworkProgress: (@Sendable () -> Void)? = nil
    ) async throws -> (sha256: String, size: Int64) {
        let writer = StreamWriter(handle: nil, expectedBytes: expectedSize(of: resource),
                                  report: progress, onNetworkProgress: onNetworkProgress)
        do {
            try await request(resource, writer: writer, box: RequestBox())
        } catch {
            throw Task.isCancelled ? CancellationError() : error
        }
        try Task.checkCancellation()
        writer.finalReport()
        let (digest, size) = try writer.result()
        return (digest, size)
    }

    /// Tamaño del archivo según Fotos, si lo expone (propiedad no documentada; se consulta de forma segura).
    public static func expectedSize(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        let value = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        return (value ?? 0) > 0 ? value : nil
    }

    /// Descarga (si hace falta, desde iCloud) el recurso original y lo escribe en `finalURL`.
    /// Escribe primero a un archivo temporal oculto, fuerza el vaciado a disco y luego renombra,
    /// para que nunca quede un archivo final a medias.
    public static func export(
        _ resource: PHAssetResource, to finalURL: URL,
        progress: (@Sendable (ExportProgress) -> Void)? = nil,
        onNetworkProgress: (@Sendable () -> Void)? = nil
    ) async throws -> ExportedFile {
        let fm = FileManager.default
        let tmp = finalURL.deletingLastPathComponent()
            .appendingPathComponent(String(localized: ".\(UUID().uuidString).partial"))
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }

        do {
            let handle = try FileHandle(forWritingTo: tmp)
            // Sin caché: la verificación posterior leerá desde el disco físico.
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

            let writer = StreamWriter(handle: handle, expectedBytes: expectedSize(of: resource),
                                      report: progress, onNetworkProgress: onNetworkProgress)
            let box = RequestBox()
            writer.onFailure = { box.cancel() }

            do {
                try await request(resource, writer: writer, box: box)
            } catch {
                try? handle.close()
                // Prioriza el error de escritura (p. ej. disco lleno) sobre el de cancelación.
                _ = try writer.result()
                throw Task.isCancelled ? CancellationError() : error
            }
            try Task.checkCancellation()
            writer.finalReport()

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
