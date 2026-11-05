import Foundation

public enum PathBuilder {
    /// Tipos de recurso que conservan su nombre original (el resto se renombra con sufijo).
    static let keepOriginalName: Set<String> = ["photo", "video", "audio", "livePhotoVideo", "alternatePhoto"]

    public static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "sin_nombre" }
        if s.count > 200 {
            let ext = fileExtension(s)
            s = String(stem(s).prefix(200 - ext.count)) + ext
        }
        return s
    }

    public static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }

    /// Devuelve la extensión con el punto (".HEIC") o "" si no tiene.
    public static func fileExtension(_ name: String) -> String {
        let e = (name as NSString).pathExtension
        return e.isEmpty ? "" : "." + e
    }

    public static func insertSuffix(_ name: String, _ suffix: String) -> String {
        stem(name) + suffix + fileExtension(name)
    }

    /// Carpeta relativa "AAAA/MM" según la fecha de creación (zona horaria local).
    public static func relativeDirectory(for date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return "SinFecha" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Nombres de archivo para todos los recursos de un elemento.
    /// Ej.: Live Photo editada → IMG_0001.HEIC, IMG_0001.MOV, IMG_0001_edited.HEIC, IMG_0001_adjustments.plist
    public static func plannedNames(for resources: [(kind: String, originalFilename: String)]) -> [String] {
        let primary = resources.first { keepOriginalName.contains($0.kind) } ?? resources.first
        let base = primary.map { stem(sanitize($0.originalFilename)) } ?? "recurso"

        var used = Set<String>()
        var result: [String] = []
        for r in resources {
            let clean = sanitize(r.originalFilename)
            var name = keepOriginalName.contains(r.kind) ? clean : "\(base)_\(r.kind)\(fileExtension(clean))"
            var n = 2
            let original = name
            while used.contains(name.lowercased()) {
                name = insertSuffix(original, "_\(n)")
                n += 1
            }
            used.insert(name.lowercased())
            result.append(name)
        }
        return result
    }
}

/// Reserva nombres de archivo para que tareas concurrentes no colisionen entre sí ni con archivos existentes.
public actor PathAllocator {
    private var reserved = Set<String>()
    public init() {}

    public func allocate(directory: URL, names: [String]) -> [String] {
        var attempt = 0
        while true {
            let candidate = attempt == 0 ? names : names.map { PathBuilder.insertSuffix($0, " (\(attempt))") }
            let keys = candidate.map { directory.appendingPathComponent($0).path.lowercased() }
            let clash = keys.contains(where: reserved.contains) || candidate.contains {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            if !clash {
                reserved.formUnion(keys)
                return candidate
            }
            attempt += 1
        }
    }

    public func release(directory: URL, names: [String]) {
        for n in names { reserved.remove(directory.appendingPathComponent(n).path.lowercased()) }
    }
}
