import Foundation
import Photos

public enum PhotoLibrary {
    public static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public static func fetchAssets(filter: MediaFilter, from: Date?, to: Date?) -> [PHAsset] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        switch filter {
        case .all:
            predicates.append(NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                          PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue))
        case .photos:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case .videos:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        }
        if let from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
        if let to { predicates.append(NSPredicate(format: "creationDate < %@", to as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Borra elementos de la fototeca (y por tanto de iCloud si Fotos de iCloud está activo).
    /// macOS muestra un diálogo de confirmación; los elementos van a «Eliminado recientemente» (30 días).
    @discardableResult
    public static func delete(localIdentifiers ids: [String]) async throws -> Int {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return 0 }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return assets.count
    }

    public static func mediaTypeName(_ t: PHAssetMediaType) -> String {
        switch t {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }

    public static func kindName(_ t: PHAssetResourceType) -> String {
        switch t {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "edited"
        case .fullSizeVideo: return "editedVideo"
        case .adjustmentData: return "adjustments"
        case .adjustmentBasePhoto: return "adjustmentBase"
        case .pairedVideo: return "livePhotoVideo"
        case .fullSizePairedVideo: return "editedLivePhotoVideo"
        case .adjustmentBasePairedVideo: return "adjustmentBaseLivePhotoVideo"
        case .adjustmentBaseVideo: return "adjustmentBaseVideo"
        case .photoProxy: return "photoProxy"
        @unknown default: return "other\(t.rawValue)"
        }
    }
}
