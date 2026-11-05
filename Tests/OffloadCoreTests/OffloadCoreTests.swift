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
