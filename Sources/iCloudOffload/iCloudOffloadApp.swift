import AppKit
import SwiftUI

@main
struct iCloudOffloadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("iCloud Offload", id: "main") {
            ContentView()
        }
        .defaultSize(width: 980, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de iCloud Offload") { AboutPanel.show() }
            }
        }
    }
}

/// Panel «Acerca de» estándar de macOS con autor, licencia y enlace al repositorio.
enum AboutPanel {
    static let author = String(localized: "Cristhian Ligio")
    static let year = "2026"
    static let repository = URL(string: "https://github.com/cristhianligio/iCloudOffload")!

    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: String(localized: "Creada por \(author)\nLicencia MIT · \(year)\n\n"), attributes: base)
        var link = base
        link[.link] = repository
        credits.append(NSAttributedString(string: "github.com/cristhianligio/iCloudOffload", attributes: link))

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: String(localized: "Copyright")): String(localized: "© \(year) \(author). Distribuida bajo la licencia MIT."),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
