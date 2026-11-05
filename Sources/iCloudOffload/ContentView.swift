import OffloadCore
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = OffloadViewModel()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                destinationSection
                selectionSection
                optionsSection
            }
            .formStyle(.grouped)
            .disabled(vm.isRunning)
            .frame(maxHeight: 470)

            Divider()
            progressSection.padding()
            Divider()
            logSection
        }
        .frame(minWidth: 680, minHeight: 820)
        .alert("¿Borrar de iCloud tras verificar?", isPresented: $confirmDelete) {
            Button("Copiar, verificar y borrar", role: .destructive) { vm.start() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Solo se borrarán los elementos cuyos archivos se hayan copiado y verificado con SHA-256. macOS pedirá confirmación por cada lote de \(vm.deleteBatchSize). Los elementos irán a «Eliminado recientemente» (30 días).")
        }
    }

    // MARK: Secciones

    private var destinationSection: some View {
        Section("Disco externo de destino") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.destination?.path ?? "Ninguna carpeta elegida")
                        .font(.body.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    if let v = vm.volume {
                        HStack(spacing: 8) {
                            Label(v.isExternal ? "Externo" : "Disco interno",
                                  systemImage: v.isExternal ? "externaldrive.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(v.isExternal ? Color.green : Color.red)
                            Text(v.name ?? "")
                            if let f = v.format { Text(f).foregroundStyle(.secondary) }
                            if let free = v.availableBytes {
                                Text("Libre: \(bytes(free))").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        if !v.isExternal {
                            Text("Elige una carpeta en un disco externo.").font(.caption).foregroundStyle(.red)
                        }
                        if v.format?.localizedCaseInsensitiveContains("MS-DOS") == true {
                            Text("FAT32 no admite archivos > 4 GB (videos largos fallarán). Usa APFS o exFAT.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if let e = vm.volumeError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Elegir…") { vm.chooseDestination() }
            }
        }
    }

    private var selectionSection: some View {
        Section("Qué copiar") {
            Picker("Tipo", selection: $vm.mediaFilter) {
                ForEach(MediaFilter.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Limitar por fecha de creación", isOn: $vm.useDateRange)
            if vm.useDateRange {
                DatePicker("Desde", selection: $vm.fromDate, displayedComponents: .date)
                DatePicker("Hasta (incluido)", selection: $vm.toDate, displayedComponents: .date)
            }
        }
    }

    private var optionsSection: some View {
        Section("Opciones") {
            Toggle(isOn: $vm.deleteAfterVerify) {
                VStack(alignment: .leading) {
                    Text("Borrar de iCloud después de verificar")
                    Text("Desactivado = solo copia y verifica (modo seguro).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if vm.deleteAfterVerify {
                Stepper("Borrar en lotes de \(vm.deleteBatchSize)", value: $vm.deleteBatchSize, in: 10...1000, step: 10)
            }
            Stepper("Descargas simultáneas: \(vm.concurrency)", value: $vm.concurrency, in: 1...8)
        }
    }

    private var progressSection: some View {
        let s = vm.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                if vm.isRunning {
                    Button("Cancelar", role: .cancel) { vm.cancel() }
                } else {
                    Button(vm.deleteAfterVerify ? "Copiar, verificar y borrar" : "Copiar y verificar") {
                        if vm.deleteAfterVerify { confirmDelete = true } else { vm.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.deleteAfterVerify ? .red : .accentColor)
                    .disabled(!vm.canStart)
                }
                Spacer()
                Button("Ver manifiesto") { vm.revealManifest() }.disabled(vm.destination == nil)
            }
            if s.pending > 0 {
                ProgressView(value: Double(s.processed), total: Double(s.pending)) {
                    Text("\(s.processed) de \(s.pending) elementos")
                }
            } else if vm.isRunning {
                ProgressView().controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    stat("En fototeca", "\(s.totalInLibrary)")
                    stat("Ya copiados", "\(s.previouslyCopied)")
                    stat("Copiados y verificados", "\(s.verified)")
                }
                GridRow {
                    stat("Fallidos", "\(s.failed)", color: s.failed > 0 ? .red : nil)
                    stat("Borrados de iCloud", "\(s.deleted)")
                    stat("Datos copiados", bytes(s.bytesCopied))
                }
            }
        }
    }

    private var logSection: some View {
        ScrollViewReader { proxy in
            List(vm.logs) { entry in
                Text(entry.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(color(for: entry.level))
                    .textSelection(.enabled)
                    .id(entry.id)
            }
            .onChange(of: vm.logs.count) {
                if let last = vm.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Utilidades

    private func stat(_ title: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).foregroundStyle(color ?? .primary)
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
