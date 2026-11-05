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
        let m = try Manifest(directory: dir)
        try await m.append(rec)
        try await m.markDeleted(["ID-1"])
    }
    // Simula una línea truncada al final
    let url = dir.appendingPathComponent(".icloud-offload/manifest.jsonl")
    let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("{\"local".utf8)); try h.close()

    let reloaded = try Manifest(directory: dir)
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
