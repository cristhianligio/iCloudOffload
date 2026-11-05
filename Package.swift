// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iCloudOffload",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iCloudOffload", targets: ["iCloudOffload"]),
    ],
    targets: [
        // Lógica: acceso a Fotos, copia, verificación, manifiesto y borrado.
        .target(name: "OffloadCore"),
        // Interfaz SwiftUI.
        .executableTarget(name: "iCloudOffload", dependencies: ["OffloadCore"]),
        .testTarget(name: "OffloadCoreTests", dependencies: ["OffloadCore"]),
    ]
)
