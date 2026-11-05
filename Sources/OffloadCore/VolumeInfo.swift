import DiskArbitration
import Foundation

/// Por qué un destino es (o no) aceptable. Solo se admiten discos externos físicos:
/// el objetivo es no consumir espacio del disco interno del Mac.
public enum DestinationEligibility: Equatable, Sendable {
    case eligible
    case bootVolume
    case internalDisk
    case diskImage
    case networkVolume
    case readOnly
    case unavailable(String)

    public var isEligible: Bool { self == .eligible }

    public var message: String {
        switch self {
        case .eligible:
            return "Disco externo válido."
        case .bootVolume, .internalDisk:
            return "Esta carpeta está en el disco interno del Mac. Elige una carpeta en un disco externo conectado (USB, Thunderbolt o tarjeta SD)."
        case .diskImage:
            return "Es una imagen de disco (.dmg): sus datos se guardan en el disco interno. Elige un disco externo físico."
        case .networkVolume:
            return "Es una unidad de red. Por fiabilidad de la verificación, solo se admiten discos externos conectados físicamente."
        case .readOnly:
            return "El disco es de solo lectura."
        case .unavailable(let reason):
            return "No se pudo leer el disco: \(reason)"
        }
    }
}

public struct VolumeInfo: Sendable, Equatable {
    public var name: String?
    public var mountPath: String
    public var isInternal: Bool?
    public var isLocal: Bool?
    public var isRootFileSystem: Bool
    public var isDiskImage: Bool
    public var isReadOnly: Bool
    public var availableBytes: Int64?
    public var totalBytes: Int64?
    public var format: String?

    /// Decisión única usada por la interfaz y por el motor.
    public var eligibility: DestinationEligibility {
        if isRootFileSystem || mountPath == "/" || mountPath.hasPrefix("/System/Volumes") { return .bootVolume }
        if isLocal == false { return .networkVolume }
        if isDiskImage { return .diskImage }
        // Si el sistema no informa, se asume interno: ante la duda, no se permite.
        if isInternal ?? true { return .internalDisk }
        if isReadOnly { return .readOnly }
        return .eligible
    }

    public var isExternal: Bool { eligibility.isEligible }

    public static func inspect(_ url: URL) throws -> VolumeInfo {
        var u = url.resolvingSymlinksInPath()
        u.removeAllCachedResourceValues()
        let v = try u.resourceValues(forKeys: [
            .volumeNameKey, .volumeURLKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
        ])
        let volumeURL = v.volume ?? u
        let disk = diskDescription(for: volumeURL)

        var isInternalDisk = v.volumeIsInternal
        if let devInternal = disk?[kDADiskDescriptionDeviceInternalKey as String] as? Bool {
            isInternalDisk = (isInternalDisk ?? false) || devInternal
        }

        return VolumeInfo(
            name: v.volumeName,
            mountPath: volumeURL.path,
            isInternal: isInternalDisk,
            isLocal: v.volumeIsLocal,
            isRootFileSystem: v.volumeIsRootFileSystem ?? false,
            isDiskImage: isDiskImage(disk),
            isReadOnly: v.volumeIsReadOnly ?? false,
            availableBytes: v.volumeAvailableCapacity.map(Int64.init),
            totalBytes: v.volumeTotalCapacity.map(Int64.init),
            format: v.volumeLocalizedFormatDescription
        )
    }

    /// Espacio libre del disco interno (donde Fotos guarda temporalmente lo descargado de iCloud).
    public static func internalAvailableBytes() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func diskDescription(for volumeURL: URL) -> [String: Any]? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return desc
    }

    static func isDiskImage(_ desc: [String: Any]?) -> Bool {
        guard let desc else { return false }
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let proto = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        return model.localizedCaseInsensitiveContains("Disk Image")
            || proto.localizedCaseInsensitiveContains("Disk Image")
            || proto.localizedCaseInsensitiveContains("Virtual Interface")
    }
}
