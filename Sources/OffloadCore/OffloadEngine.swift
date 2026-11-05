import Foundation
import Photos

/// Orquesta: escaneo → copia (concurrente) → verificación → borrado por lotes.
///
/// Garantías de seguridad:
/// - Solo se borra un elemento si TODOS sus recursos se copiaron y su SHA-256 releído del disco
///   coincide con el de los bytes entregados por Fotos.
/// - Los elementos verificados en ejecuciones anteriores se re-verifican antes de borrarlos.
/// - Si se cancela, no se borra nada más (lo pendiente se borrará en la próxima ejecución).
/// - Si el usuario rechaza el diálogo de borrado del sistema, se desactiva el borrado y se sigue copiando.
public final class OffloadEngine: @unchecked Sendable {
    public let options: OffloadOptions
    public let events: AsyncStream<OffloadEvent>
    private let continuation: AsyncStream<OffloadEvent>.Continuation
    private var summary = OffloadSummary()
    private var deletionEnabled: Bool

    public init(options: OffloadOptions) {
        self.options = options
        self.deletionEnabled = options.deleteAfterVerify
        (events, continuation) = AsyncStream.makeStream(of: OffloadEvent.self, bufferingPolicy: .unbounded)
    }

    private func emit(_ e: OffloadEvent) { continuation.yield(e) }
    private func log(_ level: LogLevel, _ msg: String) { emit(.log(level, msg)) }
    private func publish() { emit(.progress(summary)) }

    public func run() async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Copiando fotos y videos de iCloud a disco externo")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            continuation.finish()
        }
        do {
            try await pipeline()
            if Task.isCancelled { summary.cancelled = true }
        } catch is CancellationError {
            summary.cancelled = true
        } catch {
            summary.fatalError = error.localizedDescription
            log(.error, error.localizedDescription)
        }
        if summary.cancelled { log(.warning, "Proceso cancelado. No se borró nada pendiente.") }
        emit(.finished(summary))
    }

    // MARK: - Pipeline

    private func pipeline() async throws {
        let dest = options.destination

        // 1. Disco destino
        let volume = try VolumeInfo.inspect(dest)
        if options.requireExternalVolume && !volume.isExternal {
            throw OffloadError.destinationNotExternal(volume.name ?? dest.path)
        }
        if volume.isReadOnly { throw OffloadError.destinationReadOnly }
        log(.info, "Destino: \(dest.path) (\(volume.name ?? "?"), \(volume.format ?? "formato desconocido"))")

        // 2. Permisos
        switch await PhotoLibrary.requestAuthorization() {
        case .authorized: break
        case .limited: throw OffloadError.limitedAccess
        default: throw OffloadError.notAuthorized
        }

        // 3. Escaneo
        let manifest = try Manifest(directory: dest)
        let allocator = PathAllocator()
        log(.info, "Leyendo la fototeca…")
        let assets = PhotoLibrary.fetchAssets(filter: options.mediaFilter, from: options.fromDate, to: options.toDate)

        var pending: [PHAsset] = []
        var deleteQueue: [AssetRecord] = []
        for asset in assets {
            try Task.checkCancellation()
            guard let rec = await manifest.record(for: asset.localIdentifier) else {
                pending.append(asset)
                continue
            }
            summary.previouslyCopied += 1
            if deletionEnabled && rec.deletedAt == nil {
                if Verifier.verify(record: rec, root: dest) {
                    deleteQueue.append(rec)
                } else {
                    log(.warning, "Copia previa de \(rec.resources.first?.originalFilename ?? rec.localIdentifier) no coincide; se volverá a copiar.")
                    summary.previouslyCopied -= 1
                    pending.append(asset)
                }
            }
        }
        summary.totalInLibrary = assets.count
        summary.pending = pending.count
        log(.info, "\(assets.count) elementos encontrados · \(pending.count) por copiar · \(summary.previouslyCopied) ya copiados antes.")
        publish()

        if deleteQueue.count >= options.deleteBatchSize {
            try await flushDeletes(&deleteQueue, manifest: manifest)
        }

        // 4. Copia + verificación concurrente, borrado por lotes según se van verificando
        var lowSpace = false
        try await withThrowingTaskGroup(of: AssetOutcome.self) { group in
            var next = 0
            func canStartMore() -> Bool {
                guard !Task.isCancelled, !lowSpace, next < pending.count else { return false }
                if let free = (try? VolumeInfo.inspect(dest))?.availableBytes, free < options.minimumFreeBytes {
                    lowSpace = true
                    log(.error, OffloadError.lowDiskSpace(free).localizedDescription + " Se detiene la copia.")
                    return false
                }
                return true
            }

            while next < min(options.maxConcurrentExports, pending.count), canStartMore() {
                let asset = pending[next]; next += 1
                group.addTask { await self.processWithRetry(asset, allocator: allocator) }
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .success(let record):
                    try await manifest.append(record)
                    summary.copied += 1
                    summary.verified += 1
                    summary.bytesCopied += record.totalBytes
                    log(.success, "✓ \(record.resources.map(\.originalFilename).first ?? "") (\(record.resources.count) archivo/s) copiado y verificado")
                    if deletionEnabled { deleteQueue.append(record) }
                case .failure(let name, let message):
                    summary.failed += 1
                    log(.error, "✗ \(name): \(message)")
                case .cancelled:
                    break
                }
                publish()

                if !Task.isCancelled && deleteQueue.count >= options.deleteBatchSize {
                    try await flushDeletes(&deleteQueue, manifest: manifest)
                }
                if canStartMore() {
                    let asset = pending[next]; next += 1
                    group.addTask { await self.processWithRetry(asset, allocator: allocator) }
                }
            }
        }

        // 5. Último lote
        if !Task.isCancelled && !deleteQueue.isEmpty {
            try await flushDeletes(&deleteQueue, manifest: manifest)
        }
        if options.deleteAfterVerify && summary.deleted > 0 {
            log(.warning, "Los elementos borrados están en «Eliminado recientemente» de Fotos durante 30 días. Vacía esa carpeta para liberar el espacio en iCloud de inmediato.")
        }
        log(.info, "Terminado. Manifiesto: \(manifest.url.path)")
    }

    private func flushDeletes(_ queue: inout [AssetRecord], manifest: Manifest) async throws {
        guard deletionEnabled, !queue.isEmpty else { queue.removeAll(); return }
        let batch = queue
        queue.removeAll()

        // Última comprobación justo antes de borrar: los archivos siguen ahí y siguen íntegros.
        var safe: [AssetRecord] = []
        for rec in batch {
            try Task.checkCancellation()
            if Verifier.verify(record: rec, root: options.destination) {
                safe.append(rec)
            } else {
                log(.error, "Re-verificación fallida antes de borrar \(rec.localIdentifier); NO se borra.")
            }
        }
        guard !safe.isEmpty else { return }

        log(.info, "Solicitando borrar \(safe.count) elemento/s de Fotos/iCloud (confirma en el diálogo del sistema)…")
        do {
            let ids = safe.map(\.localIdentifier)
            let n = try await PhotoLibrary.delete(localIdentifiers: ids)
            try await manifest.markDeleted(ids)
            summary.deleted += n
            summary.bytesDeleted += safe.reduce(0) { $0 + $1.totalBytes }
            log(.success, "Borrados \(n) elemento/s de la fototeca.")
            publish()
        } catch {
            deletionEnabled = false
            log(.error, "No se borró el lote (\(error.localizedDescription)). Borrado desactivado para esta ejecución; la copia continúa.")
        }
    }

    // MARK: - Un elemento

    enum AssetOutcome: Sendable {
        case success(AssetRecord)
        case failure(name: String, message: String)
        case cancelled
    }

    private func processWithRetry(_ asset: PHAsset, allocator: PathAllocator) async -> AssetOutcome {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return .success(try await process(asset, allocator: allocator))
            } catch is CancellationError {
                return .cancelled
            } catch {
                if Task.isCancelled { return .cancelled }
                lastError = error
                if case OffloadError.lowDiskSpace = error { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        return .failure(name: name, message: lastError?.localizedDescription ?? "error desconocido")
    }

    private func process(_ asset: PHAsset, allocator: PathAllocator) async throws -> AssetRecord {
        let fm = FileManager.default
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw OffloadError.noResources }

        let relDir = PathBuilder.relativeDirectory(for: asset.creationDate)
        let dir = options.destination.appendingPathComponent(relDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let kinds = resources.map { PhotoLibrary.kindName($0.type) }
        let planned = PathBuilder.plannedNames(for: zip(kinds, resources).map { ($0, $1.originalFilename) })
        let names = await allocator.allocate(directory: dir, names: planned)

        var written: [URL] = []
        var records: [ResourceRecord] = []
        do {
            for (i, resource) in resources.enumerated() {
                try Task.checkCancellation()
                let url = dir.appendingPathComponent(names[i])

                // Copia
                let exported = try await ResourceExporter.export(resource, to: url)
                written.append(url)

                // Verificación: releer desde disco y comparar con el hash del stream
                guard try Verifier.verify(file: url, expectedSHA256: exported.sha256, expectedSize: exported.size) else {
                    throw OffloadError.verificationFailed(names[i])
                }

                if let date = asset.creationDate {
                    try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
                }
                records.append(ResourceRecord(kind: kinds[i], originalFilename: resource.originalFilename,
                                              relativePath: relDir + "/" + names[i],
                                              size: exported.size, sha256: exported.sha256))
            }
        } catch {
            for u in written { try? fm.removeItem(at: u) }
            await allocator.release(directory: dir, names: names)
            throw error
        }

        return AssetRecord(localIdentifier: asset.localIdentifier, creationDate: asset.creationDate,
                           mediaType: PhotoLibrary.mediaTypeName(asset.mediaType),
                           resources: records, verifiedAt: Date())
    }
}
