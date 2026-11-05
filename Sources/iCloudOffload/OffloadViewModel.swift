import AppKit
import OffloadCore
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let level: LogLevel
    let message: String
}

@MainActor
final class OffloadViewModel: ObservableObject {
    @Published var destination: URL? { didSet { refreshVolume() } }
    @Published var volume: VolumeInfo?
    @Published var volumeError: String?

    @Published var mediaFilter: MediaFilter = .all
    @Published var useDateRange = false
    @Published var fromDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @Published var toDate = Date()

    @Published var deleteAfterVerify = false
    @Published var deleteBatchSize = 100
    @Published var concurrency = 3

    @Published private(set) var isRunning = false
    @Published private(set) var summary = OffloadSummary()
    @Published private(set) var logs: [LogEntry] = []

    private var runTask: Task<Void, Never>?

    var canStart: Bool { destination != nil && !isRunning && (volume?.isExternal ?? false) && volume?.isReadOnly == false }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        panel.message = "Elige una carpeta en el disco externo donde guardar las fotos y videos"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK { destination = panel.url }
    }

    func refreshVolume() {
        guard let destination else { volume = nil; return }
        do {
            volume = try VolumeInfo.inspect(destination)
            volumeError = nil
        } catch {
            volume = nil
            volumeError = error.localizedDescription
        }
    }

    func start() {
        guard let destination, !isRunning else { return }
        var o = OffloadOptions(destination: destination)
        o.mediaFilter = mediaFilter
        if useDateRange {
            let cal = Calendar.current
            o.fromDate = cal.startOfDay(for: fromDate)
            o.toDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate))
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
        let url = destination.appendingPathComponent(".icloud-offload/manifest.jsonl")
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
