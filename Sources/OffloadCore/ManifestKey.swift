import CryptoKit
import Foundation
import Security

/// Clave secreta con la que se firma el registro de copias. Vive en el Llavero del Mac, nunca en el disco externo,
/// así que quien pueda modificar el disco no puede falsificar registros que la app acepte.
public enum ManifestKey {
    static let service = "com.cristhianligio.icloudoffload.manifest-key"
    static let account = "hmac-sha256-v1"

    /// Devuelve la clave (creándola la primera vez) o `nil` si el Llavero no está disponible o se denegó el acceso.
    public static func loadOrCreate() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { return nil }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "iCloud Offload – clave del registro de copias",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? SymmetricKey(data: data) : nil
    }
}
