import Foundation

public struct VolumeInfo: Sendable, Equatable {
    public var name: String?
    public var mountPath: String
    public var isInternal: Bool?
    public var isRemovable: Bool?
    public var isEjectable: Bool?
    public var isReadOnly: Bool
    public var availableBytes: Int64?
    public var totalBytes: Int64?
    public var format: String?

    public var isExternal: Bool {
        if let isInternal { return !isInternal }
        return mountPath.hasPrefix("/Volumes/")
    }

    public static func inspect(_ url: URL) throws -> VolumeInfo {
        var u = url
        u.removeAllCachedResourceValues()
        let v = try u.resourceValues(forKeys: [
            .volumeNameKey, .volumeURLKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
        ])
        return VolumeInfo(
            name: v.volumeName,
            mountPath: v.volume?.path ?? url.path,
            isInternal: v.volumeIsInternal,
            isRemovable: v.volumeIsRemovable,
            isEjectable: v.volumeIsEjectable,
            isReadOnly: v.volumeIsReadOnly ?? false,
            availableBytes: v.volumeAvailableCapacity.map(Int64.init),
            totalBytes: v.volumeTotalCapacity.map(Int64.init),
            format: v.volumeLocalizedFormatDescription
        )
    }
}
