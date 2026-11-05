import OffloadCore
import SwiftUI

/// Diseño según «Adopting Liquid Glass» (Apple):
/// - Componentes estándar (Form agrupado, toolbar, inspector) para que el sistema aplique Liquid Glass.
/// - Sin fondos personalizados en barras ni controles.
/// - La acción principal vive en la barra de herramientas con estilo `.glassProminent`.
/// - Botones de icono con etiqueta de accesibilidad; grupos separados con `ToolbarSpacer`.
/// - El registro de actividad, como información complementaria, va en un inspector.
struct ContentView: View {
    @StateObject private var vm = OffloadViewModel()
    @State private var showActivity = false
    @State private var confirmDelete = false
    @State private var showManifestHelp = false

    var body: some View {
        Form {
            if vm.isStopping, let sp = vm.stopProgress { StopSection(stop: sp) }
            if vm.isRunning, vm.network.isOffline || vm.network.unstable { NetworkSection(network: vm.network) }
            destinationSection
            selectionSection
            optionsSection
            progressSection
            manifestSection
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud Offload")
        .navigationSubtitle(statusSubtitle)
        .toolbar { toolbarContent }
        .inspector(isPresented: $showActivity) {
            ActivityLogView(logs: vm.logs, activeItems: vm.activeItems)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
        }
        .frame(minWidth: 620, minHeight: 640)
        .onChange(of: vm.isRunning) { _, running in if running { showActivity = true } }
        .alert("¿Borrar de iCloud tras verificar?", isPresented: $confirmDelete) {
            Button("Copiar, verificar y borrar", role: .destructive) { vm.start() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Solo se borrarán los elementos cuyos archivos se hayan copiado y verificado con SHA-256. macOS pedirá confirmación por cada lote de \(vm.deleteBatchSize). Los elementos irán a «Eliminado recientemente» durante 30 días.")
        }
    }

    // MARK: Barra de herramientas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if vm.isStopping {
                Button {} label: {
                    Label("Deteniendo…", systemImage: "hourglass").labelStyle(.titleAndIcon)
                }
                .disabled(true)
            } else if vm.isRunning {
                Button(role: .cancel) { vm.cancel() } label: {
                    Label("Detener", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .help("Detiene el proceso. Lo ya verificado queda registrado y no se borra nada más.")
            } else {
                Button {
                    if vm.deleteAfterVerify { confirmDelete = true } else { vm.start() }
                } label: {
                    Label(vm.deleteAfterVerify ? "Copiar y liberar" : "Copiar y verificar",
                          systemImage: vm.deleteAfterVerify ? "icloud.and.arrow.down" : "externaldrive.badge.checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .prominentActionStyle(destructive: vm.deleteAfterVerify)
                .disabled(!vm.canStart)
                .help(vm.canStart ? "Inicia la copia" : "Elige primero una carpeta en un disco externo")
            }
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.revealDestination() } label: {
                Label("Abrir destino en Finder", systemImage: "folder")
            }
            .disabled(vm.destination == nil)
            .help("Abre la carpeta de destino en Finder")

            Button { showActivity.toggle() } label: {
                Label("Actividad", systemImage: "list.bullet.rectangle")
            }
            .help("Muestra u oculta el registro de actividad")
        }
    }

    private var statusSubtitle: String {
        let s = vm.summary
        if vm.isStopping { return "Deteniendo…" }
        if vm.isRunning {
            if vm.network.isOffline { return "Sin conexión a internet" }
            return s.pending > 0 ? "Copiando \(s.processed) de \(s.pending)…" : "Preparando…"
        }
        if s.stopReason == .networkLost { return "Detenido por falta de conexión" }
        if s.cancelled { return "Detenido" }
        if s.fatalError != nil { return "Error" }
        if s.processed > 0 || s.deleted > 0 { return "Terminado" }
        return vm.destination == nil ? "Elige un disco externo" : "Listo para empezar"
    }

    // MARK: Secciones

    private var destinationSection: some View {
        Section {
            LabeledContent {
                Button(vm.destination == nil ? "Elegir disco…" : "Cambiar…") { vm.chooseDestination() }
            } label: {
                if let url = vm.destination {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.volume?.name ?? url.lastPathComponent)
                            Text(url.path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: vm.eligibility?.isEligible == true ? "externaldrive.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(vm.eligibility?.isEligible == true ? Color.accentColor : Color.red)
                    }
                } else {
                    Label("Ningún disco elegido", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                }
            }

            if let e = vm.eligibility, !e.isEligible {
                Label(e.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else if let err = vm.volumeError {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }

            if let v = vm.volume, v.isExternal {
                if let free = v.availableBytes, let total = v.totalBytes, total > 0 {
                    LabeledContent("Espacio libre en el disco externo") {
                        Text("\(bytes(free)) de \(bytes(total))")
                    }
                }
                if let f = v.format { LabeledContent("Formato", value: f) }
                if v.format?.localizedCaseInsensitiveContains("MS-DOS") == true {
                    Label("FAT32 no admite archivos de más de 4 GB: los videos largos fallarán. Usa APFS o exFAT.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let free = vm.internalFreeBytes {
                LabeledContent("Espacio libre en este Mac", value: bytes(free))
            }
        } header: {
            Text("Destino")
        } footer: {
            Text("Solo se admiten discos externos conectados físicamente (USB, Thunderbolt o tarjeta SD). Nunca se copia al disco interno del Mac, ni a imágenes de disco o unidades de red.")
        }
        .disabled(vm.isRunning)
    }

    private var selectionSection: some View {
        Section {
            Picker("Tipo", selection: $vm.mediaFilter) {
                ForEach(MediaFilter.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Limitar por fecha de creación", isOn: $vm.useDateRange)
            if vm.useDateRange {
                DatePicker("Desde", selection: $vm.fromDate, in: vm.fromRange, displayedComponents: .date)
                DatePicker("Hasta (incluido)", selection: $vm.toDate, in: vm.toRange, displayedComponents: .date)
            }
        } header: {
            Text("Qué copiar")
        } footer: {
            if vm.useDateRange {
                Text("Las fechas no pueden ser futuras ni anteriores a 1900, y «Desde» no puede ser posterior a «Hasta».")
            }
        }
        .disabled(vm.isRunning)
    }

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $vm.deleteAfterVerify) {
                Text("Borrar de iCloud después de verificar")
                Text("Desactivado: solo copia y verifica (modo seguro).")
            }
            if vm.deleteAfterVerify {
                Stepper(value: $vm.deleteBatchSize, in: 10...1000, step: 10) {
                    LabeledContent("Borrar en lotes de", value: "\(vm.deleteBatchSize)")
                }
            }
            Stepper(value: $vm.concurrency, in: 1...8) {
                LabeledContent("Descargas simultáneas", value: "\(vm.concurrency)")
            }
        } header: {
            Text("Opciones")
        } footer: {
            if vm.deleteAfterVerify {
                Text("Lo borrado pasa a «Eliminado recientemente» en Fotos durante 30 días. Vacía esa carpeta para liberar el espacio en iCloud de inmediato.")
            }
        }
        .disabled(vm.isRunning)
    }

    private var progressSection: some View {
        let s = vm.summary
        return Section("Progreso") {
            if s.pending > 0 {
                ProgressView(value: Double(s.processed), total: Double(s.pending)) {
                    Text("\(s.processed) de \(s.pending) elementos")
                } currentValueLabel: {
                    Text("\(bytes(s.bytesCopied)) copiados")
                }
            } else if vm.isRunning {
                ProgressView("Leyendo la fototeca…").controlSize(.small)
            }
            if let err = s.fatalError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(err, systemImage: s.stopReason == .networkLost ? "wifi.exclamationmark" : "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    if let detail = s.fatalErrorDetail { TechnicalDetail(text: detail) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    stat("En la fototeca", s.totalInLibrary, symbol: "photo.on.rectangle")
                    stat("Copiados antes", s.previouslyCopied, symbol: "clock.arrow.circlepath")
                    stat("Verificados", s.verified, symbol: "checkmark.seal")
                }
                GridRow {
                    stat("Fallidos", s.failed, symbol: "exclamationmark.triangle", tint: s.failed > 0 ? .red : nil)
                    stat("Borrados de iCloud", s.deleted, symbol: "icloud.slash")
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Liberado", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                        Text(bytes(s.bytesDeleted)).font(.title3.monospacedDigit())
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var manifestSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("En el disco externo se guarda un registro con cada foto y video copiado: dónde quedó, su tamaño, su huella digital SHA-256 y, si corresponde, cuándo se borró de iCloud.")
                Text("Sirve para **reanudar** sin volver a copiar lo ya hecho, **comprobar en el futuro** que los archivos no se han dañado y **tener constancia** de qué se borró de iCloud. No lo borres mientras quieras conservar ese historial.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            LabeledContent {
                Button("Mostrar en Finder") { vm.revealManifest() }
                    .disabled(vm.manifestSummary == nil)
                    .help("Abre la carpeta oculta .icloud-offload y selecciona manifest.jsonl")
            } label: {
                if let m = vm.manifestSummary {
                    Text("\(m.records) elementos registrados · \(m.deleted) borrados de iCloud")
                    Text(".icloud-offload/manifest.jsonl").font(.caption.monospaced())
                } else if vm.destination != nil {
                    Text("Aún no hay registro en este disco")
                    Text("Se crea al iniciar la primera copia.")
                } else {
                    Text("Elige un disco para ver su registro")
                }
            }
        } header: {
            HStack {
                Text("Registro de copias")
                Spacer()
                Button { showManifestHelp.toggle() } label: {
                    Label("¿Qué es el registro de copias?", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showManifestHelp, arrowEdge: .bottom) { manifestHelp }
            }
        }
    }

    private var manifestHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Registro de copias (manifiesto)").font(.headline)
            Text("Es un archivo de texto, `manifest.jsonl`, dentro de la carpeta oculta `.icloud-offload` del destino. Tiene una línea por evento:")
            VStack(alignment: .leading, spacing: 4) {
                Label("Elemento copiado y verificado: archivos, tamaños y SHA-256", systemImage: "checkmark.seal")
                Label("Elemento borrado de iCloud: fecha y hora", systemImage: "icloud.slash")
            }
            Text("Al volver a ejecutar la app con el mismo disco, se usa para saltar lo ya copiado y para re-verificar los archivos antes de borrar nada de iCloud.")
            Text("Puedes abrirlo con cualquier editor de texto. Para ver carpetas ocultas en Finder, pulsa ⌘⇧.").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(width: 380)
    }

    // MARK: Utilidades

    private func stat(_ title: String, _ value: Int, symbol: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.monospacedDigit()).foregroundStyle(tint ?? .primary)
        }
        .accessibilityElement(children: .combine)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

// MARK: - Liquid Glass con compatibilidad hacia atrás

extension View {
    /// `.glassProminent` en macOS 26+; `.borderedProminent` en versiones anteriores.
    @ViewBuilder
    func prominentActionStyle(destructive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(destructive ? .red : nil)
        } else {
            self.buttonStyle(.borderedProminent).tint(destructive ? .red : nil)
        }
    }
}
