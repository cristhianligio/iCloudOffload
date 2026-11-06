import Foundation

/// Comprobaciones para que ninguna ruta (del registro de copias o de carpetas del disco) salga de la carpeta destino.
/// El disco externo no es de confianza: cualquiera con acceso a él puede editar el registro o crear enlaces simbólicos.
public enum PathSafety {
    /// URL dentro de `root` para una ruta relativa del registro, o `nil` si es absoluta,
    /// contiene «..», «.» o componentes vacíos, o si (resolviendo enlaces simbólicos) sale de `root`.
    public static func resolve(_ relativePath: String, in root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let url = root.appendingPathComponent(relativePath)
        return isInside(url, root: root) ? url : nil
    }

    /// `true` si `url`, una vez resueltos los enlaces simbólicos, queda estrictamente dentro de `root`.
    /// Funciona también con rutas que aún no existen (se resuelve la parte que sí existe).
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let r = resolved(root)
        let u = resolved(url)
        return u.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// Ruta real: resuelve enlaces simbólicos del tramo que existe y añade el resto tal cual.
    /// (`resolvingSymlinksInPath` no resuelve nada si el final de la ruta todavía no existe.)
    private static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for c in rest { out.appendPathComponent(c) }
        return out.standardizedFileURL.path
    }

    /// `true` si `url` es un archivo normal y no un enlace simbólico (ni carpeta, ni dispositivo…).
    public static func isRegularFile(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return false }
        return v.isSymbolicLink != true && v.isRegularFile == true
    }
}
