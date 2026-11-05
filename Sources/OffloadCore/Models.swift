import Foundation

public enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, photos, videos
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "Fotos y videos"
        case .photos: return "Solo fotos"
        case .videos: return "Solo videos"
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
    public var requireExternalVolume: Bool = true
    /// Margen mínimo de espacio libre en el disco destino.
    public var minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

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
    public var failed = 0
    public var deleted = 0
    public var bytesCopied: Int64 = 0
    public var bytesDeleted: Int64 = 0
    public var cancelled = false
    public var fatalError: String?
    public init() {}

    public var processed: Int { copied + failed }
}

public enum LogLevel: String, Sendable { case info, success, warning, error }

public enum OffloadEvent: Sendable {
    case log(LogLevel, String)
    case progress(OffloadSummary)
    case finished(OffloadSummary)
}

public enum OffloadError: LocalizedError {
    case destinationNotExternal(String)
    case destinationReadOnly
    case notAuthorized
    case limitedAccess
    case noResources
    case emptyResource(String)
    case verificationFailed(String)
    case lowDiskSpace(Int64)

    public var errorDescription: String? {
        switch self {
        case .destinationNotExternal(let name):
            return "El destino «\(name)» no es un disco externo."
        case .destinationReadOnly:
            return "El disco destino es de solo lectura."
        case .notAuthorized:
            return "Sin permiso para acceder a Fotos. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Fotos."
        case .limitedAccess:
            return "El acceso a Fotos es limitado. Concede acceso completo para procesar toda la fototeca."
        case .noResources:
            return "El elemento no tiene recursos exportables."
        case .emptyResource(let name):
            return "Se recibió un archivo vacío: \(name)."
        case .verificationFailed(let name):
            return "La verificación SHA-256 falló para \(name)."
        case .lowDiskSpace(let bytes):
            let s = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "Espacio insuficiente en el disco destino (quedan \(s))."
        }
    }
}
