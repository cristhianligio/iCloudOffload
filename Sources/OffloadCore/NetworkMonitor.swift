import Foundation
import Network

/// Lógica pura (sin temporizadores) para decidir si la red está caída, fallando o inestable.
///
/// «Sin conexión útil» significa cualquiera de estas dos cosas:
/// - el Mac no tiene ruta de red (Wi-Fi/Ethernet caídos), o
/// - hay ruta, pero las descargas de iCloud fallan por red y desde entonces no ha llegado ningún dato.
/// Si esa situación dura `stopAfter` segundos seguidos, hay que detenerlo todo.
public struct NetworkHealth: Sendable {
    public var stopAfter: TimeInterval
    /// Ventana para considerar la conexión inestable.
    public var instabilityWindow: TimeInterval = 180
    /// Cortes o fallos dentro de la ventana para considerarla inestable.
    public var instabilityThreshold = 2

    /// Tras cuántos segundos sin recibir nada en ninguna descarga activa se considera que la red está atascada.
    public var stallGrace: TimeInterval = 20

    private(set) var pathReachable = true
    private var pathDownSince: Date?
    private var failingSince: Date?
    private var incidents: [Date] = []
    private var activeDownloads = 0
    private var lastActivity: Date?
    private var stallRecorded = false

    public init(stopAfter: TimeInterval = 60) { self.stopAfter = stopAfter }

    public mutating func downloadStarted(at now: Date) {
        if activeDownloads == 0 { lastActivity = now }
        activeDownloads += 1
    }

    public mutating func downloadEnded(at now: Date) {
        activeDownloads = max(0, activeDownloads - 1)
        lastActivity = now
        stallRecorded = false
    }

    /// Llegaron datos o progreso de alguna descarga.
    public mutating func activity(at now: Date) {
        lastActivity = now
        stallRecorded = false
        failingSince = nil
    }

    /// Hay descargas en curso pero ninguna recibe nada desde hace `stallGrace` segundos.
    func stalledSince(at now: Date) -> Date? {
        guard activeDownloads > 0, let last = lastActivity, now.timeIntervalSince(last) >= stallGrace else { return nil }
        return last
    }

    /// Registra el atasco como incidente (una sola vez por atasco) para detectar inestabilidad.
    public mutating func noteStall(at now: Date) {
        guard !stallRecorded, let since = stalledSince(at: now) else { return }
        stallRecorded = true
        incidents.append(since)
    }

    public var isPathReachable: Bool { pathReachable }

    public mutating func pathChanged(reachable: Bool, at now: Date) {
        guard reachable != pathReachable else { return }
        pathReachable = reachable
        if reachable {
            pathDownSince = nil
        } else {
            pathDownSince = now
            incidents.append(now)
        }
    }

    /// Una descarga falló por la red.
    public mutating func networkError(at now: Date) {
        if failingSince == nil { failingSince = now }
        incidents.append(now)
    }

    /// Llegaron datos desde iCloud o un elemento terminó bien: la red funciona.
    public mutating func networkSuccess(at now: Date) {
        failingSince = nil
    }

    public func offlineSince(at now: Date) -> Date? {
        [pathDownSince, failingSince, stalledSince(at: now)].compactMap { $0 }.min()
    }

    public func shouldStop(at now: Date) -> Bool {
        guard let since = offlineSince(at: now) else { return false }
        return now.timeIntervalSince(since) >= stopAfter
    }

    public func state(at now: Date) -> NetworkState {
        let since = offlineSince(at: now)
        var s = NetworkState()
        s.reachable = pathReachable
        s.failing = pathReachable && since != nil
        s.unstable = incidents.filter { now.timeIntervalSince($0) <= instabilityWindow }.count >= instabilityThreshold
        s.offlineSince = since
        s.stopDeadline = since?.addingTimeInterval(stopAfter)
        return s
    }
}

/// Observa la red del Mac con `NWPathMonitor` y combina esa señal con los errores de descarga.
public final class NetworkMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var health: NetworkHealth
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "icloudoffload.network")

    public init(stopAfter: TimeInterval) {
        health = NetworkHealth(stopAfter: stopAfter)
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.health.pathChanged(reachable: path.status == .satisfied, at: Date()) }
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }

    public var isPathReachable: Bool { lock.withLock { health.isPathReachable } }
    public func recordError() { lock.withLock { health.networkError(at: Date()) } }
    public func recordSuccess() { lock.withLock { health.networkSuccess(at: Date()) } }
    public func recordActivity() { lock.withLock { health.activity(at: Date()) } }
    public func downloadStarted() { lock.withLock { health.downloadStarted(at: Date()) } }
    public func downloadEnded() { lock.withLock { health.downloadEnded(at: Date()) } }
    public func state(at now: Date = Date()) -> NetworkState {
        lock.withLock {
            health.noteStall(at: now)
            return health.state(at: now)
        }
    }
    public func shouldStop(at now: Date = Date()) -> Bool { lock.withLock { health.shouldStop(at: now) } }

    /// Espera a que vuelva la ruta de red. Lanza `CancellationError` si se detiene el proceso.
    public func waitUntilReachable() async throws {
        while !isPathReachable {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
