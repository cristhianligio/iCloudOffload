import Foundation

/// Un error explicado en dos niveles: lenguaje coloquial para el usuario y detalle técnico
/// (dominio, código, nombre simbólico y errores subyacentes) para soporte o diagnóstico.
public struct ErrorInfo: Sendable, Equatable {
    public var friendly: String
    public var technical: String
    /// El fallo se debe a la red (descarga desde iCloud).
    public var isNetwork: Bool

    public init(friendly: String, technical: String, isNetwork: Bool = false) {
        self.friendly = friendly
        self.technical = technical
        self.isNetwork = isNetwork
    }
}

public enum ErrorDescriber {
    public static let photosDomain = "PHPhotosErrorDomain"

    public static func describe(_ error: Error) -> ErrorInfo {
        let technical = technicalDescription(error)

        if error is CancellationError {
            return ErrorInfo(friendly: "Operación detenida.", technical: technical)
        }
        if let e = error as? OffloadError {
            return ErrorInfo(friendly: e.errorDescription ?? "Error.", technical: technical)
        }
        // Busca el primer error conocido en la cadena (el error y sus subyacentes).
        for ns in chain(error as NSError) {
            if let (friendly, isNetwork) = friendlyText(for: ns) {
                return ErrorInfo(friendly: friendly, technical: technical, isNetwork: isNetwork)
            }
        }
        return ErrorInfo(
            friendly: "Ocurrió un error inesperado al procesar este elemento. No se borró nada; se volverá a intentar en la próxima ejecución.",
            technical: technical)
    }

    /// Detalle técnico, p. ej. «PHPhotosErrorDomain 3169 (networkError) · No se ha podido completar la operación.»
    public static func technicalDescription(_ error: Error) -> String {
        if let e = error as? OffloadError { return "OffloadError.\(e)" }
        if error is CancellationError { return "CancellationError" }
        return chain(error as NSError).map { ns in
            var s = "\(ns.domain) \(ns.code)"
            if let name = symbolicName(domain: ns.domain, code: ns.code) { s += " (\(name))" }
            s += " · \(ns.localizedDescription)"
            return s
        }.joined(separator: " ← ")
    }

    static func chain(_ error: NSError) -> [NSError] {
        var out: [NSError] = [error]
        var current = error
        while let u = current.userInfo[NSUnderlyingErrorKey] as? NSError, out.count < 5 {
            out.append(u)
            current = u
        }
        return out
    }

    static func symbolicName(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case (photosDomain, -1): return "internalError"
        case (photosDomain, 3072): return "userCancelled"
        case (photosDomain, 3114): return "libraryVolumeOffline"
        case (photosDomain, 3164): return "networkAccessRequired"
        case (photosDomain, 3169): return "networkError"
        case (photosDomain, 3201): return "identifierNotFound"
        case (photosDomain, 3300): return "changeNotSupported"
        case (photosDomain, 3301): return "operationInterrupted"
        case (photosDomain, 3302): return "invalidResource"
        case (photosDomain, 3303): return "missingResource"
        case (photosDomain, 3305): return "notEnoughSpace"
        case (photosDomain, 3306): return "requestNotSupportedForAsset"
        case (photosDomain, 3307): return "limitExceeded"
        case (photosDomain, 3310): return "accessRestricted"
        case (photosDomain, 3311): return "accessUserDenied"
        case (NSPOSIXErrorDomain, _): return posixNames[Int32(code)]
        default: return nil
        }
    }

    static let posixNames: [Int32: String] = [
        EPERM: "EPERM", ENOENT: "ENOENT", EIO: "EIO", ENXIO: "ENXIO", EACCES: "EACCES",
        ENODEV: "ENODEV", EFBIG: "EFBIG", ENOSPC: "ENOSPC", EROFS: "EROFS", EINTR: "EINTR",
        ENETDOWN: "ENETDOWN", ENETUNREACH: "ENETUNREACH", ECONNRESET: "ECONNRESET",
        ETIMEDOUT: "ETIMEDOUT", ENOTCONN: "ENOTCONN", ECANCELED: "ECANCELED",
    ]

    private static let retryNote = "No se borró nada; se volverá a intentar en la próxima ejecución."

    static func friendlyText(for ns: NSError) -> (String, Bool)? {
        switch ns.domain {
        case photosDomain:
            switch ns.code {
            case 3164, 3169:
                return ("No se pudo descargar el archivo desde iCloud por un problema con la conexión a internet. \(retryNote)", true)
            case 3072:
                return ("La operación se canceló en el diálogo de macOS.", false)
            case 3114, 3142, 3143:
                return ("La fototeca de Fotos no está disponible en este momento (¿está en un disco desconectado o se cambió de fototeca?).", false)
            case 3201:
                return ("Este elemento ya no existe en la fototeca; quizá se borró desde otro dispositivo.", false)
            case 3300:
                return ("Fotos no permite borrar este elemento (por ejemplo, si pertenece a un álbum compartido).", false)
            case 3301:
                return ("La operación se interrumpió (Fotos se cerró o el Mac entró en reposo). \(retryNote)", false)
            case 3302, 3303:
                return ("Fotos no encuentra el archivo original de este elemento o está dañado. Ábrelo en Fotos para comprobarlo. No se borró nada.", false)
            case 3305:
                return ("No hay espacio suficiente en el disco interno del Mac para que Fotos descargue este archivo de iCloud. Libera espacio y vuelve a intentarlo.", false)
            case 3306:
                return ("Fotos no permite exportar este tipo de elemento. No se borró nada.", false)
            case 3310, 3311:
                return ("La app no tiene permiso para acceder a Fotos. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Fotos.", false)
            default:
                return ("Fotos no pudo completar la operación con este elemento. \(retryNote)", false)
            }
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return ("Se perdió la conexión a internet mientras se descargaba el archivo de iCloud. \(retryNote)", true)
            default:
                return nil
            }
        case NSPOSIXErrorDomain:
            return posixText(Int32(ns.code))
        case NSCocoaErrorDomain:
            switch ns.code {
            case CocoaError.fileWriteOutOfSpace.rawValue:
                return ("El disco externo se ha llenado. Libera espacio o usa otro disco.", false)
            case CocoaError.fileWriteVolumeReadOnly.rawValue:
                return ("El disco externo es de solo lectura.", false)
            case CocoaError.fileWriteNoPermission.rawValue:
                return ("No hay permiso para escribir en la carpeta de destino.", false)
            case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileWriteUnknown.rawValue:
                return ("No se pudo escribir en el disco externo. ¿Se desconectó? \(retryNote)", false)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func posixText(_ code: Int32) -> (String, Bool)? {
        switch code {
        case ENOSPC: return ("El disco externo se ha llenado. Libera espacio o usa otro disco.", false)
        case EFBIG: return ("El archivo es demasiado grande para el formato del disco (FAT32 admite como máximo 4 GB). Usa un disco APFS o exFAT.", false)
        case EROFS: return ("El disco externo es de solo lectura.", false)
        case EACCES, EPERM: return ("No hay permiso para escribir en la carpeta de destino.", false)
        case EIO, ENXIO, ENODEV, ENOENT: return ("No se pudo leer o escribir en el disco externo. ¿Se desconectó? \(retryNote)", false)
        case ENETDOWN, ENETUNREACH, ECONNRESET, ETIMEDOUT, ENOTCONN:
            return ("Se perdió la conexión a internet mientras se descargaba el archivo de iCloud. \(retryNote)", true)
        default: return nil
        }
    }
}
