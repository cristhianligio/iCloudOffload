import Foundation
import Photos

/// Orquesta: escaneo → copia (concurrente) → verificación → borrado por lotes.
///
/// Garantías de seguridad:
/// - Solo se borra un elemento si TODOS sus recursos se copiaron y su SHA-256 releído del disco
///   coincide con el de los bytes entregados por Fotos.
/// - Los elementos verificados en ejecuciones anteriores se re-verifican antes de borrarlos.
/// - Si se detiene (por el usuario o por falta de red), no se borra nada más; lo pendiente
///   se borrará en la próxima ejecución.
/// - Si el usuario rechaza el diálogo de borrado del sistema, se desactiva el borrado y se sigue copiando.
/// - Sin red: no se empiezan descargas nuevas; si pasan `networkStopTimeout` segundos sin conexión
///   útil, se detienen todas las copias y borrados.
public final class OffloadEngine: @unchecked Sendable {
    public let options: OffloadOptions
    public let events: AsyncStream<OffloadEvent>
    private let continuation: AsyncStream<OffloadEvent>.Continuation
    private let network: NetworkMonitor

    // Solo lo toca la tarea del pipeline (y `run` cuando ya terminó).
    private var summary = OffloadSummary()
    private var deletionEnabled: Bool

    // Compartido entre hilos (cancelación, vigilante de red, pipeline): protegido por `lock`.
    private let lock = NSLock()
    private var inFlight = 0
    private var deletionInProgress = false
    private var stopProgress: StopProgress?

    public init(options: OffloadOptions) {
        self.options = options
        self.deletionEnabled = options.deleteAfterVerify
        self.network = NetworkMonitor(stopAfter: options.networkStopTimeout)
        (events, continuation) = AsyncStream.makeStream(of: OffloadEvent.self, bufferingPolicy: .unbounded)
    }

    private func emit(_ e: OffloadEvent) { continuation.yield(e) }
    private func log(_ level: LogLevel, _ msg: String, detail: String? = nil) { emit(.log(level, msg, detail: detail)) }
    private func publish() { emit(.progress(summary)) }

    // MARK: - Ejecución y detención

    public func run() async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Copiando fotos y videos de iCloud a disco externo")
        network.start()
        defer {
            network.stop()
            ProcessInfo.processInfo.endActivity(activity)
            continuation.finish()
        }

        let pipelineTask = Task { try await self.pipeline() }
        let watchdog = Task { await self.watchNetwork(pipelineTask) }

        await withTaskCancellationHandler {
            do {
                try await pipelineTask.value
            } catch is CancellationError {
                // Detención pedida: se resume abajo.
            } catch {
                let info = ErrorDescriber.describe(error)
                summary.fatalError = info.friendly
                summary.fatalErrorDetail = info.technical
                log(.error, info.friendly, detail: info.technical)
            }
        } onCancel: {
            self.beginStopping(.user)
            pipelineTask.cancel()
        }
        watchdog.cancel()

        if let stop = lock.withLock({ stopProgress }) {
            summary.cancelled = true
            summary.stopReason = stop.reason
            switch stop.reason {
            case .user:
                log(.warning, "Proceso detenido. Lo ya copiado y verificado está a salvo; no se borró nada pendiente.")
            case .networkLost:
                let e = OffloadError.networkLost(options.networkStopTimeout)
                summary.fatalError = e.errorDescription
                summary.fatalErrorDetail = "OffloadError.networkLost · sin conexión útil ≥ \(Int(options.networkStopTimeout)) s"
            }
            lock.withLock { stopProgress?.remaining = 0 }
            if let sp = lock.withLock({ stopProgress }) { emit(.stopping(sp)) }
        }
        emit(.finished(summary))
    }

    private func beginStopping(_ reason: StopReason) {
        let sp: StopProgress? = lock.withLock {
            guard stopProgress == nil else { return nil }
            let pending = inFlight + (deletionInProgress ? 1 : 0)
            stopProgress = StopProgress(reason: reason, startedAt: Date(), total: pending,
                                        remaining: pending, deletionInProgress: deletionInProgress)
            return stopProgress
        }
        if let sp { emit(.stopping(sp)) }
    }

    /// Recalcula cuánto falta para detenerse del todo y lo comunica.
    private func updateStopping() {
        let sp: StopProgress? = lock.withLock {
            guard var s = stopProgress else { return nil }
            s.remaining = inFlight + (deletionInProgress ? 1 : 0)
            s.deletionInProgress = deletionInProgress
            stopProgress = s
            return s
        }
        if let sp { emit(.stopping(sp)) }
    }

    private var isStopping: Bool { lock.withLock { stopProgress != nil } }

    // MARK: - Vigilancia de red

    private func watchNetwork(_ pipeline: Task<Void, Error>) async {
        var last = NetworkState()
        let timeout = Int(options.networkStopTimeout)
        while !Task.isCancelled {
            let now = Date()
            let st = network.state(at: now)
            if st != last {
                if st.isOffline && !last.isOffline {
                    log(.warning, st.reachable
                        ? "Las descargas desde iCloud están fallando por problemas de red. Si no se recupera en \(timeout) s, se detendrá todo."
                        : "Se perdió la conexión a internet. Las descargas nuevas quedan en espera; si no vuelve en \(timeout) s, se detendrá todo.")
                }
                if !st.isOffline && last.isOffline {
                    log(.success, "Conexión restablecida. Se reanudan las descargas.")
                }
                if st.unstable && !last.unstable {
                    log(.warning, "La conexión a internet es inestable: algunas descargas pueden fallar y se reintentarán.")
                }
                emit(.network(st))
                last = st
            }
            if network.shouldStop(at: now) {
                log(.error, OffloadError.networkLost(options.networkStopTimeout).errorDescription ?? "",
                    detail: "Sin conexión útil desde \(st.offlineSince.map { "\($0)" } ?? "?")")
                beginStopping(.networkLost)
                pipeline.cancel()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Pipeline

    private func pipeline() async throws {
        let dest = options.destination

        // 1. Disco destino
        let volume = try VolumeInfo.inspect(dest)
        let eligibility = volume.eligibility
        guard eligibility.isEligible else { throw OffloadError.destinationNotEligible(eligibility.message) }
        log(.info, "Destino: \(dest.path) (\(volume.name ?? "?"), \(volume.format ?? "formato desconocido"))")
        if let free = VolumeInfo.internalAvailableBytes(), free < options.minimumInternalFreeBytes {
            throw OffloadError.lowInternalSpace(free)
        }

        // 2. Permisos
        switch await PhotoLibrary.requestAuthorization() {
        case .authorized: break
        case .limited: throw OffloadError.limitedAccess
        default: throw OffloadError.notAuthorized
        }

        // 3. Escaneo
        let manifest = try Manifest(directory: dest)
        removeLeftoverPartials(in: dest)
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
                if try Verifier.verify(record: rec, root: dest) {
                    deleteQueue.append(rec)
                } else {
                    log(.warning, "La copia anterior de \(rec.resources.first?.originalFilename ?? rec.localIdentifier) no coincide con la registrada; se volverá a copiar.")
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

        // 4. Copia + verificación concurrente; borrado por lotes según se van verificando
        try await withThrowingTaskGroup(of: AssetOutcome.self) { group in
            var next = 0
            var halted = false   // sin espacio, disco desconectado…
            var running = 0

            func resourcesAllowStart() -> Bool {
                guard let vol = try? VolumeInfo.inspect(dest), vol.eligibility.isEligible,
                      FileManager.default.fileExists(atPath: dest.path) else {
                    log(.error, "El disco destino ya no está disponible (¿se desconectó?). Se detiene la copia; no se borra nada pendiente.")
                    return false
                }
                if let free = vol.availableBytes, free < options.minimumFreeBytes {
                    log(.error, OffloadError.lowDiskSpace(free).localizedDescription + " Se detiene la copia.")
                    return false
                }
                if let free = VolumeInfo.internalAvailableBytes(), free < options.minimumInternalFreeBytes {
                    log(.error, OffloadError.lowInternalSpace(free).localizedDescription + " Se detiene la copia.")
                    return false
                }
                return true
            }

            while true {
                // Rellenar hasta el máximo de descargas simultáneas
                while running < options.maxConcurrentExports, next < pending.count, !halted,
                      !Task.isCancelled, network.isPathReachable {
                    guard resourcesAllowStart() else { halted = true; break }
                    let asset = pending[next]; next += 1
                    running += 1
                    lock.withLock { inFlight += 1 }
                    group.addTask { await self.processWithRetry(asset, allocator: allocator) }
                }

                if running == 0 {
                    if halted || Task.isCancelled || next >= pending.count { break }
                    // Nada en curso y sin red: esperar (el vigilante detiene todo a los 60 s).
                    try await network.waitUntilReachable()
                    continue
                }

                guard let outcome = try await group.next() else { break }
                running -= 1
                lock.withLock { inFlight -= 1 }
                updateStopping()

                switch outcome {
                case .success(let record):
                    try await manifest.append(record)
                    summary.copied += 1
                    summary.verified += 1
                    summary.bytesCopied += record.totalBytes
                    if deletionEnabled { deleteQueue.append(record) }
                case .failure:
                    summary.failed += 1
                case .cancelled:
                    break
                }
                publish()

                if !Task.isCancelled && deleteQueue.count >= options.deleteBatchSize {
                    try await flushDeletes(&deleteQueue, manifest: manifest)
                }
            }
        }
        try Task.checkCancellation()

        // 5. Último lote
        if !deleteQueue.isEmpty {
            try await flushDeletes(&deleteQueue, manifest: manifest)
        }
        if options.deleteAfterVerify && summary.deleted > 0 {
            log(.warning, "Los elementos borrados están en «Eliminado recientemente» de Fotos durante 30 días. Vacía esa carpeta para liberar el espacio en iCloud de inmediato.")
        }
        log(.info, "Terminado. Registro de copias: \(manifest.url.path)")
    }

    /// Borra temporales «.UUID.partial» que quedaron de una ejecución interrumpida (cierre forzado, corte de luz…).
    private func removeLeftoverPartials(in dest: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dest, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return }
        var removed = 0
        for case let url as URL in e {
            let name = url.lastPathComponent
            if name == ".icloud-offload" { e.skipDescendants(); continue }
            if name.hasPrefix("."), name.hasSuffix(".partial"), (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { log(.info, "Se eliminaron \(removed) archivo(s) temporal(es) de una copia anterior interrumpida.") }
    }

    private func flushDeletes(_ queue: inout [AssetRecord], manifest: Manifest) async throws {
        guard deletionEnabled, !queue.isEmpty else { queue.removeAll(); return }
        let batch = queue
        queue.removeAll()

        // Última comprobación justo antes de borrar: los archivos siguen ahí y siguen íntegros.
        var safe: [AssetRecord] = []
        for rec in batch {
            if try Verifier.verify(record: rec, root: options.destination) {
                safe.append(rec)
            } else {
                log(.error, "La copia de \(rec.resources.first?.originalFilename ?? "un elemento") ya no coincide con la registrada (¿se modificó o dañó el archivo?). No se borra de iCloud.",
                    detail: "Re-verificación SHA-256 fallida · \(rec.localIdentifier)")
            }
        }
        try Task.checkCancellation()
        guard !safe.isEmpty else { return }

        log(.info, "Solicitando borrar \(safe.count) elemento/s de Fotos/iCloud (confirma en el diálogo de macOS)…")
        lock.withLock { deletionInProgress = true }
        defer {
            lock.withLock { deletionInProgress = false }
            updateStopping()
        }
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
            let info = ErrorDescriber.describe(error)
            log(.error, "No se borró el lote: \(info.friendly) El borrado queda desactivado en esta ejecución; la copia continúa.",
                detail: info.technical)
        }
    }

    // MARK: - Un elemento

    enum AssetOutcome: Sendable {
        case success(AssetRecord)
        case failure(ErrorInfo)
        case cancelled
    }

    private func processWithRetry(_ asset: PHAsset, allocator: PathAllocator) async -> AssetOutcome {
        let id = asset.localIdentifier
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? id
        emit(.itemStarted(id: id, name: name))

        var lastInfo: ErrorInfo?
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let record = try await process(asset, allocator: allocator)
                network.recordSuccess()
                emit(.itemFinished(id: id, result: .success(bytes: record.totalBytes, files: record.resources.count)))
                return .success(record)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    emit(.itemFinished(id: id, result: .cancelled))
                    return .cancelled
                }
                let info = ErrorDescriber.describe(error)
                lastInfo = info
                if info.isNetwork { network.recordError() }
                if case OffloadError.lowDiskSpace = error { break }
                if attempt == maxAttempts { break }

                do {
                    if !network.isPathReachable {
                        emit(.itemProgress(ItemProgress(id: id, fraction: nil, bytes: 0, expectedBytes: nil, phase: .waitingForNetwork)))
                        try await network.waitUntilReachable()
                    }
                    emit(.itemProgress(ItemProgress(id: id, fraction: nil, bytes: 0, expectedBytes: nil, phase: .retrying(attempt: attempt + 1))))
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                } catch {
                    emit(.itemFinished(id: id, result: .cancelled))
                    return .cancelled
                }
            }
        }
        let info = lastInfo ?? ErrorInfo(friendly: "Error desconocido.", technical: "desconocido")
        emit(.itemFinished(id: id, result: .failure(info)))
        return .failure(info)
    }

    private func process(_ asset: PHAsset, allocator: PathAllocator) async throws -> AssetRecord {
        let fm = FileManager.default
        let id = asset.localIdentifier
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw OffloadError.noResources }

        let relDir = PathBuilder.relativeDirectory(for: asset.creationDate)
        let dir = options.destination.appendingPathComponent(relDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let kinds = resources.map { PhotoLibrary.kindName($0.type) }
        let planned = PathBuilder.plannedNames(for: zip(kinds, resources).map { ($0, $1.originalFilename) })
        let names = await allocator.allocate(directory: dir, names: planned)

        // Tamaños esperados para calcular el progreso del elemento completo
        let sizes = resources.map { ResourceExporter.expectedSize(of: $0) }
        let totalKnown: Int64? = sizes.contains(where: { $0 == nil }) ? nil : sizes.reduce(0) { $0 + ($1 ?? 0) }
        let count = Double(resources.count)

        var written: [URL] = []
        var records: [ResourceRecord] = []
        var doneBytes: Int64 = 0
        do {
            for (i, resource) in resources.enumerated() {
                try Task.checkCancellation()
                let url = dir.appendingPathComponent(names[i])
                let base = doneBytes
                let index = Double(i)

                // Copia (con progreso). Se cuenta como descarga activa para detectar atascos de red.
                // (Solo la descarga: la verificación posterior no usa la red.)
                network.downloadStarted()
                let exported: ExportedFile
                do {
                    defer { network.downloadEnded() }
                    exported = try await ResourceExporter.export(
                    resource, to: url,
                    progress: { [weak self] p in
                        let overall: Double?
                        if let total = totalKnown, total > 0 {
                            overall = min(1, Double(base + p.bytesWritten) / Double(total))
                        } else if let f = p.fraction {
                            overall = (index + f) / count
                        } else {
                            overall = i == 0 && p.bytesWritten == 0 ? nil : index / count
                        }
                        self?.emit(.itemProgress(ItemProgress(id: id, fraction: overall, bytes: base + p.bytesWritten,
                                                              expectedBytes: totalKnown, phase: .downloading)))
                    },
                    onNetworkProgress: { [weak self] in self?.network.recordActivity() })
                }
                written.append(url)
                doneBytes += exported.size

                // Verificación: releer desde disco y comparar con el hash del stream
                emit(.itemProgress(ItemProgress(id: id, fraction: totalKnown.map { Double(doneBytes) / Double(max($0, 1)) } ?? (index + 1) / count,
                                                bytes: doneBytes, expectedBytes: totalKnown, phase: .verifying)))
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
