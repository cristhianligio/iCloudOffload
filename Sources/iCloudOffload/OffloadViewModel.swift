import AppKit
import OffloadCore
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let level: LogLevel
    let message: String
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

    private var runTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        internalFreeBytes = VolumeInfo.internalAvailableBytes()
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
        runTask?.cancel()
        append(.warning, "Cancelando… (se terminan las copias en curso)")
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
        case .log(let level, let msg): append(level, msg)
        case .progress(let s): summary = s
        case .finished(let s): summary = s
        }
    }

    private func append(_ level: LogLevel, _ msg: String) {
        logs.append(LogEntry(level: level, message: msg))
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
    }
}
