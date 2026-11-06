import AppKit
import OffloadCore
import SwiftUI

// MARK: - Detalle técnico plegable

/// Muestra el detalle técnico de un error plegado bajo el mensaje coloquial, con opción de copiarlo.
struct TechnicalDetail: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Label(expanded ? String(localized: "Ocultar detalles técnicos") : String(localized: "Mostrar detalles técnicos"),
                      systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if expanded {
            HStack(alignment: .top) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copiar detalle técnico", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copiar detalle técnico")
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Registro de actividad (inspector)

struct ActivityLogView: View {
    let logs: [LogEntry]
    let activeItems: [String: ItemProgress]

    var body: some View {
        Group {
            if logs.isEmpty {
                ContentUnavailableView("Sin actividad", systemImage: "list.bullet.rectangle",
                                       description: Text("Aquí verás cada archivo copiado, verificado y borrado."))
            } else {
                ScrollViewReader { proxy in
                    List(logs) { entry in
                        ActivityRow(entry: entry, progress: entry.itemID.flatMap { activeItems[$0] })
                            .id(entry.id)
                    }
                    .onChange(of: logs.count) {
                        if let last = logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Actividad")
    }
}

struct ActivityRow: View {
    let entry: LogEntry
    /// Presente mientras el elemento se está copiando.
    let progress: ItemProgress?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message).font(.callout).textSelection(.enabled)
                if let progress { ItemProgressView(progress: progress) }
                if let detail = entry.detail { TechnicalDetail(text: detail) }
            }
        } icon: {
            if progress != nil {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
        .contextMenu {
            Button("Copiar mensaje") { copy(entry.message) }
            if let detail = entry.detail {
                Button("Copiar detalle técnico") { copy(detail) }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var symbol: String {
        switch entry.level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Barra de progreso de un elemento en copia, bajo su fila en el registro de actividad.
struct ItemProgressView: View {
    let progress: ItemProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let f = progress.fraction, [.downloading, .verifying, .confirming].contains(progress.phase) {
                ProgressView(value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(phaseText)
                Spacer()
                Text(bytesText).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phaseText), \(bytesText)")
    }

    private var phaseText: String {
        switch progress.phase {
        case .downloading: return String(localized: "Descargando de iCloud y copiando")
        case .verifying: return String(localized: "Verificando (SHA-256)")
        case .confirming: return String(localized: "Comparando la copia anterior con el original de iCloud")
        case .retrying(let n): return String(localized: "Reintentando (intento \(n) de 3)")
        case .waitingForNetwork: return String(localized: "Esperando conexión a internet")
        }
    }

    private var bytesText: String {
        guard progress.bytes > 0 else { return "" }
        let done = ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
        if let total = progress.expectedBytes, total > 0 {
            return "\(done) de \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return done
    }
}

// MARK: - Aviso de red

struct NetworkSection: View {
    let network: NetworkState

    var body: some View {
        Section {
            if network.isOffline {
                VStack(alignment: .leading, spacing: 6) {
                    Label(network.reachable ? String(localized: "La red está fallando") : String(localized: "Sin conexión a internet"),
                          systemImage: network.reachable ? "wifi.exclamationmark" : "wifi.slash")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(network.reachable
                         ? String(localized: "Las descargas desde iCloud fallan por problemas de red. Revisa tu Wi-Fi o tu router.")
                         : String(localized: "Las descargas nuevas están en espera hasta que vuelva la conexión."))
                    if let deadline = network.stopDeadline {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded(.up)))
                            Text("Si la conexión no vuelve, se detendrán todas las copias y borrados en **\(left) s**.")
                                .monospacedDigit()
                        }
                    }
                }
            } else if network.unstable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Conexión inestable", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Se han detectado cortes o fallos de red en los últimos minutos. Algunas descargas pueden fallar; se reintentarán automáticamente y nada se borra sin verificar.")
                }
            }
        }
    }
}

// MARK: - Detención en curso

struct StopSection: View {
    let stop: StopProgress

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(stop.reason == .networkLost ? String(localized: "Deteniendo por falta de conexión") : String(localized: "Deteniendo"),
                      systemImage: stop.reason == .networkLost ? "wifi.slash" : "stop.circle")
                    .font(.headline)

                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ProgressView(value: stop.fraction) {
                        Text(stop.remaining == 0
                             ? String(localized: "Terminando…")
                             : String(localized: "Esperando a que terminen \(stop.remaining) de \(stop.total) operaciones en curso"))
                    } currentValueLabel: {
                        Text(estimate(now: ctx.date)).monospacedDigit()
                    }
                }

                if stop.deletionInProgress {
                    Label("Hay un lote de borrado esperando respuesta de Fotos. Si aparece el diálogo de macOS, respóndelo para terminar.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Las copias a medias se descartan. Lo ya copiado y verificado se conserva y no se borra nada más de iCloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tiempo estimado según lo que han tardado en detenerse las operaciones que ya terminaron.
    private func estimate(now: Date) -> String {
        let elapsed = now.timeIntervalSince(stop.startedAt)
        let done = stop.total - stop.remaining
        guard stop.remaining > 0 else { return String(localized: "Listo") }
        guard done > 0 else { return String(localized: "Calculando… (\(Int(elapsed)) s)") }
        let eta = max(1, elapsed / Double(done) * Double(stop.remaining))
        return eta < 60 ? String(localized: "≈ \(Int(eta.rounded(.up))) s restantes") : String(localized: "≈ \(Int((eta / 60).rounded(.up))) min restantes")
    }
}
