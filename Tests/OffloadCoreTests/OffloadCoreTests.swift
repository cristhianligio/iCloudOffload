import CryptoKit
import Foundation
import Testing
@testable import OffloadCore

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("offload-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Test func sha256OfKnownContent() throws {
    let dir = try tempDir()
    let f = dir.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: f)
    let (digest, size) = try FileHasher.sha256(of: f)
    #expect(size == 3)
    #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func verifierDetectsCorruption() throws {
    let dir = try tempDir()
    let f = dir.appendingPathComponent("x.bin")
    try Data("hola mundo".utf8).write(to: f)
    let (digest, size) = try FileHasher.sha256(of: f)
    #expect(try Verifier.verify(file: f, expectedSHA256: digest, expectedSize: size))
    try Data("hola mundO".utf8).write(to: f)
    #expect(try !Verifier.verify(file: f, expectedSHA256: digest, expectedSize: size))
}

@Test func sanitizeNames() {
    #expect(PathBuilder.sanitize("a/b:c.jpg") == "a_b_c.jpg")
    #expect(PathBuilder.sanitize("  ..hidden.png ") == "hidden.png")
    #expect(PathBuilder.sanitize("") == "sin_nombre")
}

@Test func relativeDirectoryByMonth() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let d = cal.date(from: DateComponents(year: 2023, month: 7, day: 14))!
    #expect(PathBuilder.relativeDirectory(for: d, calendar: cal) == "2023/07")
    #expect(PathBuilder.relativeDirectory(for: nil) == "SinFecha")
}

@Test func plannedNamesForEditedLivePhoto() {
    let names = PathBuilder.plannedNames(for: [
        ("photo", "IMG_0001.HEIC"),
        ("livePhotoVideo", "IMG_0001.MOV"),
        ("edited", "FullSizeRender.heic"),
        ("adjustments", "Adjustments.plist"),
    ])
    #expect(names == ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0001_edited.heic", "IMG_0001_adjustments.plist"])
}

@Test func plannedNamesDeduplicateCaseInsensitive() {
    let names = PathBuilder.plannedNames(for: [("photo", "a.jpg"), ("alternatePhoto", "A.JPG")])
    #expect(names == ["a.jpg", "A_2.JPG"])
}

@Test func allocatorAvoidsCollisions() async throws {
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("IMG_1.HEIC"))
    let alloc = PathAllocator()
    let first = await alloc.allocate(directory: dir, names: ["IMG_1.HEIC", "IMG_1.MOV"])
    #expect(first == ["IMG_1 (1).HEIC", "IMG_1 (1).MOV"])
    let second = await alloc.allocate(directory: dir, names: ["IMG_1.HEIC", "IMG_1.MOV"])
    #expect(second == ["IMG_1 (2).HEIC", "IMG_1 (2).MOV"])
}

@Test func manifestRoundTripAndDeletion() async throws {
    let dir = try tempDir()
    let rec = AssetRecord(localIdentifier: "ID-1", creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                          mediaType: "image",
                          resources: [ResourceRecord(kind: "photo", originalFilename: "IMG.HEIC",
                                                     relativePath: "2023/11/IMG.HEIC", size: 10, sha256: "abc")],
                          verifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
    do {
        let m = try Manifest(directory: dir, key: nil)
        try await m.append(rec)
        try await m.markDeleted(["ID-1"])
    }
    // Simula una línea truncada al final
    let url = dir.appendingPathComponent(".icloud-offload/manifest.jsonl")
    let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("{\"local".utf8)); try h.close()

    let reloaded = try Manifest(directory: dir, key: nil)
    let r = await reloaded.record(for: "ID-1")
    #expect(r?.resources == rec.resources)
    #expect(r?.deletedAt != nil)
    #expect(await reloaded.count == 1)
}

// MARK: - Fechas realistas

@Test func datesCannotBeInTheFuture() {
    let now = Date()
    let future = now.addingTimeInterval(86_400 * 30)
    let (f, t) = DateRangePolicy.clamp(from: now.addingTimeInterval(-86_400), to: future, now: now)
    #expect(t == now)
    #expect(f <= t)
    #expect(DateRangePolicy.toRange(from: f, now: now).upperBound == now)
    #expect(DateRangePolicy.fromRange(to: future, now: now).upperBound == now)
}

@Test func fromIsNeverAfterTo() {
    let now = Date()
    let to = now.addingTimeInterval(-86_400 * 10)
    let (f, t) = DateRangePolicy.clamp(from: now.addingTimeInterval(-86_400), to: to, now: now)
    #expect(f == t)
}

@Test func datesNotBefore1900() {
    let ancient = Date(timeIntervalSince1970: -5_000_000_000)  // ~1811
    let (f, _) = DateRangePolicy.clamp(from: ancient, to: Date())
    #expect(f == DateRangePolicy.earliest)
}

@Test func fetchBoundsIncludeWholeLastDay() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15))!
    let from = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 9))!
    let b = DateRangePolicy.fetchBounds(from: from, to: now, calendar: cal, now: now)
    #expect(b.start == cal.date(from: DateComponents(year: 2026, month: 1, day: 10)))
    #expect(b.endExclusive == cal.date(from: DateComponents(year: 2026, month: 11, day: 6)))
}

// MARK: - Solo discos externos

@Test func bootVolumeIsRejected() throws {
    #expect(try VolumeInfo.inspect(URL(fileURLWithPath: "/")).eligibility == .bootVolume)
}

@Test func homeFolderIsRejected() throws {
    let e = try VolumeInfo.inspect(FileManager.default.homeDirectoryForCurrentUser).eligibility
    #expect(!e.isEligible)
}

@Test func tempFolderIsRejected() throws {
    #expect(try !VolumeInfo.inspect(tempDir()).eligibility.isEligible)
}

/// Diagnóstico manual: OFFLOAD_CHECK_PATHS="/Volumes/Disco:/otra/ruta" swift test --filter diagnoseVolumes
@Test func diagnoseVolumes() throws {
    guard let paths = ProcessInfo.processInfo.environment["OFFLOAD_CHECK_PATHS"] else { return }
    for p in paths.split(separator: ":") {
        let v = try VolumeInfo.inspect(URL(fileURLWithPath: String(p)))
        print("VOLCHECK \(p) → \(v.eligibility) internal=\(String(describing: v.isInternal)) diskImage=\(v.isDiskImage) local=\(String(describing: v.isLocal)) format=\(v.format ?? "?")")
    }
}

// MARK: - Mensajes de error

@Test func photosNetworkErrorIsExplainedInPlainLanguage() {
    let err = NSError(domain: "PHPhotosErrorDomain", code: 3169,
                      userInfo: [NSLocalizedDescriptionKey: "No se ha podido completar la operación."])
    let info = ErrorDescriber.describe(err)
    #expect(info.isNetwork)
    #expect(info.friendly.contains("conexión a internet"))
    #expect(!info.friendly.contains("3169"))
    #expect(info.technical.contains("PHPhotosErrorDomain 3169 (networkError)"))
}

@Test func underlyingErrorIsUsedWhenTopLevelIsUnknown() {
    let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let outer = NSError(domain: "AlgoRaro", code: 7, userInfo: [NSUnderlyingErrorKey: inner])
    let info = ErrorDescriber.describe(outer)
    #expect(info.friendly.contains("se ha llenado"))
    #expect(info.technical.contains("AlgoRaro 7"))
    #expect(info.technical.contains("ENOSPC"))
}

@Test func unknownErrorStillHasFriendlyText() {
    let info = ErrorDescriber.describe(NSError(domain: "X", code: 1))
    #expect(info.friendly.contains("No se borró nada"))
    #expect(info.technical.hasPrefix("X 1"))
}

// MARK: - Red

@Test func stopsAfterOneMinuteWithoutNetwork() {
    var h = NetworkHealth(stopAfter: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.pathChanged(reachable: false, at: t0)
    #expect(h.state(at: t0).isOffline)
    #expect(h.state(at: t0).stopDeadline == t0.addingTimeInterval(60))
    #expect(!h.shouldStop(at: t0.addingTimeInterval(59)))
    #expect(h.shouldStop(at: t0.addingTimeInterval(60)))
}

@Test func reconnectionCancelsTheCountdown() {
    var h = NetworkHealth(stopAfter: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.pathChanged(reachable: false, at: t0)
    h.pathChanged(reachable: true, at: t0.addingTimeInterval(30))
    #expect(!h.shouldStop(at: t0.addingTimeInterval(90)))
    #expect(!h.state(at: t0.addingTimeInterval(90)).isOffline)
}

@Test func failingDownloadsCountAsNoConnection() {
    var h = NetworkHealth(stopAfter: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.networkError(at: t0)
    #expect(h.state(at: t0).failing)
    #expect(h.shouldStop(at: t0.addingTimeInterval(61)))
    h.networkSuccess(at: t0.addingTimeInterval(10))
    #expect(!h.shouldStop(at: t0.addingTimeInterval(61)))
}

@Test func repeatedDropsMarkConnectionUnstable() {
    var h = NetworkHealth(stopAfter: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.pathChanged(reachable: false, at: t0)
    h.pathChanged(reachable: true, at: t0.addingTimeInterval(5))
    #expect(!h.state(at: t0.addingTimeInterval(6)).unstable)
    h.pathChanged(reachable: false, at: t0.addingTimeInterval(40))
    h.pathChanged(reachable: true, at: t0.addingTimeInterval(45))
    #expect(h.state(at: t0.addingTimeInterval(50)).unstable)
    // Pasada la ventana de 3 minutos, deja de considerarse inestable
    #expect(!h.state(at: t0.addingTimeInterval(400)).unstable)
}

// MARK: - Progreso

@Test func exportProgressUsesBestEstimate() {
    #expect(ExportProgress(downloadFraction: 0.4, bytesWritten: 0, expectedBytes: 100).fraction == 0.4)
    #expect(ExportProgress(downloadFraction: nil, bytesWritten: 50, expectedBytes: 100).fraction == 0.5)
    #expect(ExportProgress(downloadFraction: nil, bytesWritten: 50, expectedBytes: nil).fraction == nil)
}

@Test func stopProgressFraction() {
    let sp = StopProgress(reason: .user, startedAt: Date(), total: 4, remaining: 1, deletionInProgress: false)
    #expect(sp.fraction == 0.75)
    #expect(StopProgress(reason: .user, startedAt: Date(), total: 0, remaining: 0, deletionInProgress: false).fraction == 1)
}

@Test func silentStalledDownloadCountsAsNoConnection() {
    var h = NetworkHealth(stopAfter: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.downloadStarted(at: t0)
    #expect(!h.state(at: t0.addingTimeInterval(10)).isOffline)   // margen de gracia
    #expect(h.state(at: t0.addingTimeInterval(25)).isOffline)    // atascada
    #expect(h.shouldStop(at: t0.addingTimeInterval(60)))
    h.activity(at: t0.addingTimeInterval(30))                     // llegan datos
    #expect(!h.shouldStop(at: t0.addingTimeInterval(60)))
    h.downloadEnded(at: t0.addingTimeInterval(31))
    #expect(!h.state(at: t0.addingTimeInterval(500)).isOffline)  // sin descargas no hay atasco
}

// MARK: - Seguridad: rutas del registro

@Test func manifestPathsCannotEscapeDestination() throws {
    let root = try tempDir()
    #expect(PathSafety.resolve("../../../../etc/hosts", in: root) == nil)
    #expect(PathSafety.resolve("/etc/hosts", in: root) == nil)
    #expect(PathSafety.resolve("2026/../../x", in: root) == nil)
    #expect(PathSafety.resolve("2026//x", in: root) == nil)
    #expect(PathSafety.resolve("./x", in: root) == nil)
    #expect(PathSafety.resolve("", in: root) == nil)
    #expect(PathSafety.resolve("2026/01/IMG.HEIC", in: root) != nil)
}

@Test func verifierRejectsRecordPointingOutside() throws {
    let root = try tempDir()
    let (d, s) = try FileHasher.sha256(of: URL(fileURLWithPath: "/etc/hosts"))
    let rec = AssetRecord(localIdentifier: "X", creationDate: nil, mediaType: "image",
        resources: [ResourceRecord(kind: "photo", originalFilename: "x", relativePath: "../../../../../../etc/hosts",
                                   size: s, sha256: d)], verifiedAt: Date())
    #expect(try Verifier.verify(record: rec, root: root) == false)
}

@Test func symlinkedFolderOrFileIsRejected() throws {
    let root = try tempDir()
    let outside = try tempDir()
    let fm = FileManager.default
    // Carpeta «2026» que en realidad apunta fuera del destino
    try fm.createSymbolicLink(at: root.appendingPathComponent("2026"), withDestinationURL: outside)
    #expect(PathSafety.isInside(root.appendingPathComponent("2026/01"), root: root) == false)
    try fm.createDirectory(at: outside.appendingPathComponent("01"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: outside.appendingPathComponent("01/a.heic"))
    #expect(PathSafety.resolve("2026/01/a.heic", in: root) == nil)
    // Archivo que es un enlace simbólico (aunque apunte dentro)
    try fm.createDirectory(at: root.appendingPathComponent("2025"), withIntermediateDirectories: true)
    try Data("y".utf8).write(to: root.appendingPathComponent("2025/real.heic"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("2025/link.heic"),
                              withDestinationURL: root.appendingPathComponent("2025/real.heic"))
    #expect(PathSafety.isRegularFile(root.appendingPathComponent("2025/real.heic")))
    #expect(!PathSafety.isRegularFile(root.appendingPathComponent("2025/link.heic")))
}

// MARK: - Seguridad: firma del registro

private func sampleRecord(_ id: String = "ID-1") -> AssetRecord {
    AssetRecord(localIdentifier: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image",
                resources: [ResourceRecord(kind: "photo", originalFilename: "IMG.HEIC",
                                           relativePath: "2023/11/IMG.HEIC", size: 10, sha256: "abc")],
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
}

@Test func signedManifestIsTrustedOnlyWithSameKey() async throws {
    let dir = try tempDir()
    let key = SymmetricKey(size: .bits256)
    do {
        let m = try Manifest(directory: dir, key: key)
        try await m.append(sampleRecord())
        try await m.markDeleted(["ID-1"])
    }
    let same = try Manifest(directory: dir, key: key)
    #expect(await same.entry(for: "ID-1")?.trusted == true)
    #expect(await same.entry(for: "ID-1")?.record.deletedAt != nil)
    #expect(await same.entry(for: "ID-1")?.record.mac == nil)
    #expect(try await Manifest(directory: dir, key: SymmetricKey(size: .bits256)).entry(for: "ID-1")?.trusted == false)
    #expect(try await Manifest(directory: dir, key: nil).entry(for: "ID-1")?.trusted == false)
}

@Test func tamperedOrUnsignedLinesAreNotTrusted() async throws {
    let dir = try tempDir()
    let key = SymmetricKey(size: .bits256)
    do { try await Manifest(directory: dir, key: key).append(sampleRecord()) }
    let url = Manifest.fileURL(in: dir)

    // 1. Se cambia el hash en la línea firmada (p. ej. tras sustituir el archivo)
    let original = try String(contentsOf: url, encoding: .utf8)
    try original.replacingOccurrences(of: "\"abc\"", with: "\"fff\"").write(to: url, atomically: true, encoding: .utf8)
    #expect(try await Manifest(directory: dir, key: key).entry(for: "ID-1")?.trusted == false)

    // 2. Se añade al final una línea sin firma para el mismo elemento (la última manda)
    try original.write(to: url, atomically: true, encoding: .utf8)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    var forged = sampleRecord(); forged.resources[0].sha256 = "fff"
    let h = try FileHandle(forWritingTo: url); try h.seekToEnd()
    try h.write(contentsOf: try enc.encode(forged) + Data("\n".utf8)); try h.close()
    let m = try Manifest(directory: dir, key: key)
    #expect(await m.entry(for: "ID-1")?.trusted == false)
    #expect(await m.entry(for: "ID-1")?.record.resources[0].sha256 == "fff")
}
