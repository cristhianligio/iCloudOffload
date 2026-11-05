import AppKit
import OffloadCore
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    var level: LogLevel
    var message: String
    /// Detalle técnico del error (opcional, se muestra plegado).
    var detail: String?
    /// Si la fila representa un elemento en copia, su identificador (para mostrar su barra de progreso).
    var itemID: String?
}

/// Rechaza en el propio panel de selección cualquier carpeta que no esté en un disco externo físico.
private final class DestinationPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        let eligibility: DestinationEligibility
        do { eligibility = try VolumeInfo.inspect(url).eligibility } catch {
            eligibility = .unavailable(error.localizedDescription)
        }
        guard eligibility.isEligible else {
            throw NSError(domain: "iCloudOffload", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Esta carpeta no se puede usar como destino.",
                NSLocalizedRecoverySuggestionErrorKey: eligibility.message,
            ])
        }
    }
}

@MainActor
final class OffloadViewModel: ObservableObject {
    @Published private(set) var destination: URL?
    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var volumeError: String?
    @Published private(set) var internalFreeBytes: Int64?
    @Published private(set) var manifestSummary: (records: Int, deleted: Int)?

    @Published var mediaFilter: MediaFilter = .all
    @Published var useDateRange = false
    @Published var fromDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date() {
        didSet { clampDates() }
    }
    @Published var toDate = Date() {
        didSet { clampDates() }
    }

    @Published var deleteAfterVerify = false
    @Published var deleteBatchSize = 100
    @Published var concurrency = 3

    @Published private(set) var isRunning = false
    @Published private(set) var summary = OffloadSummary()
    @Published private(set) var logs: [LogEntry] = []
    /// Progreso de los elementos que se están copiando ahora mismo.
    @Published private(set) var activeItems: [String: ItemProgress] = [:]
    @Published private(set) var network = NetworkState()
    /// No es nil mientras se están deteniendo las operaciones en curso.
    @Published private(set) var stopProgress: StopProgress?

    private var itemNames: [String: String] = [:]
    private var runTask: Task<Void, Never>?

    var isStopping: Bool { isRunning && stopProgress != nil }
    private var observers: [NSObjectProtocol] = []

    init() {
        internalFreeBytes = VolumeInfo.internalAvailableBytes()
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLOAD_UI_DEMO"] != nil { loadDemoState() }
        #endif
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolume() }
            })
        }
    }

    var eligibility: DestinationEligibility? { volume?.eligibility }

    var canStart: Bool { destination != nil && !isRunning && eligibility?.isEligible == true }

    var fromRange: ClosedRange<Date> { DateRangePolicy.fromRange(to: toDate) }
    var toRange: ClosedRange<Date> { DateRangePolicy.toRange(from: fromDate) }

    // MARK: Destino

    func chooseDestination() {
        let panel = NSOpenPanel()
        let delegate = DestinationPanelDelegate()
        panel.delegate = delegate
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar esta carpeta"
        panel.message = "Elige un disco externo (o una carpeta dentro de él). No se admite el disco interno del Mac."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        let response = panel.runModal()
        withExtendedLifetime(delegate) {}
        if response == .OK, let url = panel.url {
            destination = url
            refreshVolume()
        }
    }

    func refreshVolume() {
        internalFreeBytes = VolumeInfo.internalAvailableBytes()
        guard let destination else { volume = nil; manifestSummary = nil; return }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            volume = nil
            volumeError = "El disco se desconectó."
            manifestSummary = nil
            return
        }
        do {
            volume = try VolumeInfo.inspect(destination)
            volumeError = nil
        } catch {
            volume = nil
            volumeError = error.localizedDescription
        }
        manifestSummary = Manifest.summary(in: destination)
    }

    // MARK: Fechas

    private func clampDates() {
        let (f, t) = DateRangePolicy.clamp(from: fromDate, to: toDate)
        // Solo se reasigna si cambia, para no entrar en bucle con didSet.
        if f != fromDate { fromDate = f }
        if t != toDate { toDate = t }
    }

    // MARK: Ejecución

    func start() {
        guard let destination, canStart else { return }
        var o = OffloadOptions(destination: destination)
        o.mediaFilter = mediaFilter
        if useDateRange {
            let b = DateRangePolicy.fetchBounds(from: fromDate, to: toDate)
            o.fromDate = b.start
            o.toDate = b.endExclusive
        }
        o.deleteAfterVerify = deleteAfterVerify
        o.deleteBatchSize = max(1, deleteBatchSize)
        o.maxConcurrentExports = max(1, concurrency)

        let engine = OffloadEngine(options: o)
        logs.removeAll()
        activeItems.removeAll()
        itemNames.removeAll()
        network = NetworkState()
        stopProgress = nil
        summary = OffloadSummary()
        isRunning = true

        runTask = Task.detached { await engine.run() }
        Task { [weak self] in
            for await event in engine.events { self?.apply(event) }
            self?.isRunning = false
            self?.refreshVolume()
        }
    }

    func cancel() {
        guard isRunning, stopProgress == nil else { return }
        runTask?.cancel()
    }

    func revealManifest() {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Manifest.fileURL(in: destination)])
    }

    func revealDestination() {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    private func apply(_ event: OffloadEvent) {
        switch event {
        case .log(let level, let msg, let detail):
            append(LogEntry(level: level, message: msg, detail: detail))
        case .progress(let s):
            summary = s
        case .itemStarted(let id, let name):
            itemNames[id] = name
            activeItems[id] = ItemProgress(id: id, fraction: nil, bytes: 0, expectedBytes: nil, phase: .downloading)
            append(LogEntry(level: .info, message: name, itemID: id))
        case .itemProgress(let p):
            if activeItems[p.id] != nil { activeItems[p.id] = p }
        case .itemFinished(let id, let result):
            activeItems[id] = nil
            finishItemRow(id: id, result: result)
        case .network(let n):
            network = n
        case .stopping(let sp):
            stopProgress = sp
        case .finished(let s):
            summary = s
            activeItems.removeAll()
        }
    }

    private func finishItemRow(id: String, result: ItemResult) {
        let name = itemNames[id] ?? id
        guard let i = logs.lastIndex(where: { $0.itemID == id }) else { return }
        switch result {
        case .success(let bytes, let files):
            logs[i].level = .success
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            logs[i].message = "\(name) · \(files == 1 ? "1 archivo" : "\(files) archivos"), \(size) · copiado y verificado"
        case .failure(let info):
            logs[i].level = .error
            logs[i].message = "\(name): \(info.friendly)"
            logs[i].detail = info.technical
        case .cancelled:
            logs[i].level = .warning
            logs[i].message = "\(name): detenido antes de terminar. No se borró de iCloud."
        }
    }

    #if DEBUG
    /// Solo en compilación de desarrollo: rellena la interfaz con estados de ejemplo
    /// (sin tocar Fotos ni discos) para revisar visualmente el diseño.
    private func loadDemoState() {
        isRunning = true
        summary.totalInLibrary = 120; summary.pending = 40; summary.copied = 12; summary.verified = 12
        summary.failed = 1; summary.bytesCopied = 1_800_000_000
        let mode = ProcessInfo.processInfo.environment["OFFLOAD_UI_DEMO"] ?? ""
        apply(.log(.info, "40 elementos por copiar"))
        apply(.itemStarted(id: "a", name: "IMG_4211.HEIC"))
        apply(.itemFinished(id: "a", result: .success(bytes: 3_400_000, files: 2)))
        apply(.itemStarted(id: "b", name: "DJI_20261010_185103_419_orig_eis.mp4"))
        apply(.itemFinished(id: "b", result: .failure(ErrorDescriber.describe(
            NSError(domain: "PHPhotosErrorDomain", code: 3169,
                    userInfo: [NSLocalizedDescriptionKey: "No se ha podido completar la operación."])))))
        apply(.itemStarted(id: "c", name: "IMG_4215.MOV"))
        apply(.itemProgress(ItemProgress(id: "c", fraction: 0.42, bytes: 210_000_000, expectedBytes: 500_000_000, phase: .downloading)))
        apply(.itemStarted(id: "d", name: "IMG_4216.HEIC"))
        apply(.itemProgress(ItemProgress(id: "d", fraction: 0.9, bytes: 4_000_000, expectedBytes: 4_400_000, phase: .verifying)))
        apply(.itemStarted(id: "e", name: "IMG_4217.MOV"))
        apply(.itemProgress(ItemProgress(id: "e", fraction: nil, bytes: 0, expectedBytes: nil, phase: .waitingForNetwork)))
        var n = NetworkState()
        n.reachable = false
        n.unstable = true
        n.offlineSince = Date()
        n.stopDeadline = Date().addingTimeInterval(42)
        apply(.network(n))
        if mode == "stop" {
            apply(.stopping(StopProgress(reason: .networkLost, startedAt: Date().addingTimeInterval(-6),
                                         total: 3, remaining: 1, deletionInProgress: true)))
        }
    }
    #endif

    private func append(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
    }
}
