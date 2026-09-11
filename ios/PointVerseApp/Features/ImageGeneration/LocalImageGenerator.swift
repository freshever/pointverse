import CoreML
import Foundation
import PointVerseKit
import StableDiffusion
import UIKit
import ZIPFoundation

actor LocalImageGenerator {
    private let registry: ModelRegistry
    private let rootURL: URL

    init(registry: ModelRegistry, rootURL: URL) {
        self.registry = registry
        self.rootURL = rootURL
    }

    func generate(prompt: String) async throws -> URL {
        let manifest = ModelSelection.selectedImageModel()
        guard await registry.isInstalled(manifest) else { throw PointVerseError.modelNotInstalled }
        let archiveURL = await registry.installedURL(for: manifest)
        let resourcesURL = try prepareResources(archiveURL: archiveURL, manifest: manifest)
        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = .cpuAndNeuralEngine
        let pipeline = try StableDiffusionPipeline(
            resourcesAt: resourcesURL,
            controlNet: [],
            configuration: modelConfiguration,
            disableSafety: false,
            reduceMemory: true
        )
        try pipeline.loadResources()
        defer { pipeline.unloadResources() }

        var configuration = PipelineConfiguration(prompt: prompt)
        configuration.stepCount = 20
        configuration.imageCount = 1
        configuration.seed = UInt32.random(in: 0..<UInt32.max)
        let results = try pipeline.generateImages(configuration: configuration)
        guard let optionalImage = results.first, let cgImage = optionalImage,
              let data = UIImage(cgImage: cgImage).pngData() else { throw PointVerseError.invalidModelOutput }

        let outputDirectory = rootURL.appending(path: "generated-images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appending(path: UUID().uuidString + ".png")
        try data.write(to: outputURL, options: Data.WritingOptions.atomic)
        return outputURL
    }

    private func prepareResources(archiveURL: URL, manifest: ModelManifest) throws -> URL {
        let destination = rootURL.appending(path: "image-models/" + manifest.id, directoryHint: .isDirectory)
        if let resources = findResources(in: destination) { return resources }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archiveURL, to: destination)
        guard let resources = findResources(in: destination) else { throw PointVerseError.modelNotInstalled }
        return resources
    }

    private func findResources(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "vocab.json" {
            let directory = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.appending(path: "VAEDecoder.mlmodelc").path) { return directory }
        }
        return nil
    }
}
