import Foundation

public enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, photos, videos
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return String(localized: "Fotos y videos")
        case .photos: return String(localized: "Solo fotos")
        case .videos: return String(localized: "Solo videos")
        }
    }
}

public struct OffloadOptions: Sendable {
    public var destination: URL
    public var mediaFilter: MediaFilter = .all
    /// Inclusive.
    public var fromDate: Date?
    /// Exclusivo (el inicio del día siguiente al elegido).
    public var toDate: Date?
    /// Si es false, solo copia y verifica (modo seguro).
    public var deleteAfterVerify: Bool = false
    /// Cuántos elementos verificados se acumulan antes de pedir el borrado a Fotos.
    /// Cada lote muestra un diálogo de confirmación del sistema.
    public var deleteBatchSize: Int = 100
    public var maxConcurrentExports: Int = 3
    /// Margen mínimo de espacio libre en el disco destino.
    public var minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Margen mínimo en el disco interno del Mac: Fotos almacena allí temporalmente los
    /// originales que descarga de iCloud. Si baja de esto, la copia se detiene (se puede reanudar).
    public var minimumInternalFreeBytes: Int64 = 3 * 1024 * 1024 * 1024
    /// Si no hay conexión útil durante este tiempo, se detienen todas las copias y borrados.
    public var networkStopTimeout: TimeInterval = 60

    public init(destination: URL) { self.destination = destination }
}

public struct ResourceRecord: Codable, Sendable, Equatable {
    public var kind: String
    public var originalFilename: String
    /// Ruta relativa a la carpeta destino.
    public var relativePath: String
    public var size: Int64
    public var sha256: String

    public init(kind: String, originalFilename: String, relativePath: String, size: Int64, sha256: String) {
        self.kind = kind
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }
}

public struct AssetRecord: Codable, Sendable, Equatable {
    public var localIdentifier: String
    public var creationDate: Date?
    public var mediaType: String
    public var resources: [ResourceRecord]
    public var verifiedAt: Date
    public var deletedAt: Date?
    /// Firma HMAC-SHA256 de la línea del registro (solo en disco; ver `Manifest`).
    public var mac: String?

    public init(localIdentifier: String, creationDate: Date?, mediaType: String,
                resources: [ResourceRecord], verifiedAt: Date, deletedAt: Date? = nil) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.mediaType = mediaType
        self.resources = resources
        self.verifiedAt = verifiedAt
        self.deletedAt = deletedAt
    }

    public var totalBytes: Int64 { resources.reduce(0) { $0 + $1.size } }
}

public struct OffloadSummary: Sendable, Equatable {
    public var totalInLibrary = 0
    public var pending = 0
    public var previouslyCopied = 0
    public var copied = 0
    public var verified = 0
    /// Copias anteriores sin firma válida que se confirmaron contra iCloud.
    public var confirmed = 0
    public var failed = 0
    public var deleted = 0
    public var bytesCopied: Int64 = 0
    public var bytesDeleted: Int64 = 0
    public var cancelled = false
    public var stopReason: StopReason?
    public var fatalError: String?
    public var fatalErrorDetail: String?
    public init() {}

    public var processed: Int { copied + failed }
}

public enum LogLevel: String, Sendable { case info, success, warning, error }

// MARK: - Progreso por elemento

public enum ItemPhase: Sendable, Equatable {
    case downloading
    case verifying
    /// Comparando una copia anterior (de un registro sin firma válida) con el original de iCloud.
    case confirming
    case retrying(attempt: Int)
    case waitingForNetwork
}

public struct ItemProgress: Sendable, Equatable {
    public var id: String
    /// 0…1, o nil si todavía no se conoce el tamaño.
    public var fraction: Double?
    public var bytes: Int64
    public var expectedBytes: Int64?
    public var phase: ItemPhase

    public init(id: String, fraction: Double?, bytes: Int64, expectedBytes: Int64?, phase: ItemPhase) {
        self.id = id
        self.fraction = fraction
        self.bytes = bytes
        self.expectedBytes = expectedBytes
        self.phase = phase
    }
}

public enum ItemResult: Sendable, Equatable {
    case success(bytes: Int64, files: Int)
    /// Una copia anterior se comprobó contra el original de iCloud y coincide (no hizo falta copiar de nuevo).
    case confirmed(bytes: Int64, files: Int)
    case failure(ErrorInfo)
    case cancelled
}

// MARK: - Red

public struct NetworkState: Sendable, Equatable {
    /// El Mac tiene una ruta de red (Wi-Fi/Ethernet) utilizable.
    public var reachable = true
    /// Hay ruta, pero las descargas de iCloud fallan por red de forma continuada.
    public var failing = false
    /// Se han detectado cortes o fallos repetidos en los últimos minutos.
    public var unstable = false
    /// Desde cuándo no hay conexión útil (sin ruta o fallando).
    public var offlineSince: Date?
    /// Momento en que se detendrá todo si la conexión no vuelve.
    public var stopDeadline: Date?
    public init() {}

    public var isOffline: Bool { offlineSince != nil }
}

// MARK: - Detención

public enum StopReason: Sendable, Equatable {
    case user
    case networkLost
}

public struct StopProgress: Sendable, Equatable {
    public var reason: StopReason
    public var startedAt: Date
    /// Operaciones en curso cuando se pidió detener.
    public var total: Int
    /// Operaciones que aún no han terminado.
    public var remaining: Int
    /// Un lote de borrado está esperando la respuesta de Fotos (no se puede interrumpir).
    public var deletionInProgress: Bool

    public var fraction: Double { total == 0 ? 1 : Double(total - remaining) / Double(total) }

    public init(reason: StopReason, startedAt: Date, total: Int, remaining: Int, deletionInProgress: Bool) {
        self.reason = reason
        self.startedAt = startedAt
        self.total = total
        self.remaining = remaining
        self.deletionInProgress = deletionInProgress
    }
}

public enum OffloadEvent: Sendable {
    case log(LogLevel, String, detail: String? = nil)
    case progress(OffloadSummary)
    case itemStarted(id: String, name: String)
    case itemProgress(ItemProgress)
    case itemFinished(id: String, result: ItemResult)
    case network(NetworkState)
    case stopping(StopProgress)
    case finished(OffloadSummary)
}

public enum OffloadError: LocalizedError {
    case destinationNotEligible(String)
    case lowInternalSpace(Int64)
    case notAuthorized
    case limitedAccess
    case noResources
    case emptyResource(String)
    case verificationFailed(String)
    case lowDiskSpace(Int64)
    case networkLost(TimeInterval)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .destinationNotEligible(let reason):
            return reason
        case .lowInternalSpace(let bytes):
            let s = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(localized: "Queda poco espacio en el disco interno del Mac (\(s)). Fotos lo necesita para descargar temporalmente los originales de iCloud. Libera espacio y vuelve a iniciar: se reanudará donde se quedó.")
        case .notAuthorized:
            return String(localized: "Sin permiso para acceder a Fotos. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Fotos.")
        case .limitedAccess:
            return String(localized: "El acceso a Fotos es limitado. Concede acceso completo para procesar toda la fototeca.")
        case .noResources:
            return String(localized: "El elemento no tiene recursos exportables.")
        case .emptyResource(let name):
            return String(localized: "Se recibió un archivo vacío: \(name).")
        case .verificationFailed(let name):
            return String(localized: "La verificación SHA-256 falló para \(name).")
        case .lowDiskSpace(let bytes):
            let s = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(localized: "Espacio insuficiente en el disco destino (quedan \(s)).")
        case .networkLost(let seconds):
            return String(localized: "Se detuvo todo porque no hubo conexión a internet durante más de \(Int(seconds)) segundos. Lo ya copiado y verificado está a salvo en el disco; vuelve a iniciar cuando la conexión sea estable y continuará donde se quedó.")
        case .unsafePath(let path):
            return String(localized: "La carpeta «\(path)» del disco destino apunta fuera de él (es un enlace simbólico). Por seguridad no se copia ahí; elimina o renombra ese enlace.")
        }
    }
}
