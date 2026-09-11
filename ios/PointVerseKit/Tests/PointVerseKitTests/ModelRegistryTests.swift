import Foundation
import Testing
@testable import PointVerseKit

@Test func qwenManifestIsPinnedAndFitsModelDirectory() {
    let manifest = ModelManifest.qwen3_0_6BQ8
    #expect(manifest.id == "qwen3-0.6b-q8_0")
    #expect(manifest.filename.hasSuffix(".gguf"))
    #expect(manifest.sha256.count == 64)
    #expect(manifest.minimumFreeDiskBytes > manifest.displayByteCount)
}

@Test func imageManifestIsPinnedAndDownloadable() {
    let manifest = ModelManifest.stableDiffusion21Base6Bit
    #expect(manifest.filename.hasSuffix(".zip"))
    #expect(manifest.sha256.count == 64)
    #expect(manifest.minimumFreeDiskBytes > manifest.displayByteCount)
    #expect(ModelSelection.imageModels.contains(manifest))
}

@Test func modelInstallsOnlyAfterChecksumVerification() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ModelManifest(
        id: "fixture",
        revision: "1",
        filename: "fixture.bin",
        downloadURL: URL(string: "https://example.invalid/fixture.bin")!,
        displayByteCount: 3,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        license: "test",
        minimumFreeDiskBytes: 0
    )
    let registry = ModelRegistry(rootURL: root)
    let partial = try await registry.prepareForDownload(manifest)
    try Data("abc".utf8).write(to: partial)

    let installed = try await registry.installPartial(manifest)
    #expect(FileManager.default.fileExists(atPath: installed.path))
    #expect(await registry.isInstalled(manifest))
}

@Test func modelRejectsInvalidChecksum() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ModelManifest(
        id: "fixture",
        revision: "1",
        filename: "fixture.bin",
        downloadURL: URL(string: "https://example.invalid/fixture.bin")!,
        displayByteCount: 3,
        sha256: String(repeating: "0", count: 64),
        license: "test",
        minimumFreeDiskBytes: 0
    )
    let registry = ModelRegistry(rootURL: root)
    let partial = try await registry.prepareForDownload(manifest)
    try Data("abc".utf8).write(to: partial)

    await #expect(throws: PointVerseError.modelChecksumMismatch) {
        try await registry.installPartial(manifest)
    }
    #expect(!(await registry.isInstalled(manifest)))
}

@Test func preparingDownloadKeepsExistingPartialDataForResume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ModelManifest(
        id: "resume-fixture", revision: "1", filename: "resume.bin",
        downloadURL: URL(string: "https://example.invalid/resume.bin")!, displayByteCount: 3,
        sha256: String(repeating: "0", count: 64), license: "test", minimumFreeDiskBytes: 0
    )
    let registry = ModelRegistry(rootURL: root)
    let partial = try await registry.prepareForDownload(manifest)
    try Data("part".utf8).write(to: partial)
    _ = try await registry.prepareForDownload(manifest)
    #expect(try Data(contentsOf: partial) == Data("part".utf8))
}
