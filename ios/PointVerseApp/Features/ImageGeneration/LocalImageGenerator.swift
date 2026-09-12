import CoreML
import Foundation
import PointVerseKit
import StableDiffusion
import UIKit
import ZIPFoundation

actor LocalImageGenerator {
    private let registry: ModelRegistry
    private let rootURL: URL
    private let executionGate: ModelExecutionGate

    init(registry: ModelRegistry, rootURL: URL, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.rootURL = rootURL
        self.executionGate = executionGate
    }

    func generate(prompt: String, progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        await executionGate.acquire()
        defer { Task { await executionGate.release() } }
        let safePrompt = Self.enhancedPrompt(prompt)
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

        var configuration = PipelineConfiguration(prompt: safePrompt)
        // DPM-Solver++ preserves useful structure at a lower step count. Keeping
        // staged loading avoids retaining the text encoder, UNet and VAE together.
        configuration.stepCount = 40
        configuration.guidanceScale = 7.5
        configuration.schedulerType = .dpmSolverMultistepScheduler
        configuration.negativePrompt = Self.negativePrompt(for: safePrompt)
        configuration.imageCount = 1
        configuration.seed = UInt32.random(in: 0..<UInt32.max)
        let results = try pipeline.generateImages(configuration: configuration) { progress in
            let total = max(1, progress.stepCount)
            progressHandler(min(1, max(0, Double(progress.step) / Double(total))))
            return true
        }
        guard let optionalImage = results.first, let cgImage = optionalImage,
              let data = UIImage(cgImage: cgImage).pngData() else { throw PointVerseError.invalidModelOutput }

        let outputDirectory = rootURL.appending(path: "generated-images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appending(path: UUID().uuidString + ".png")
        try data.write(to: outputURL, options: Data.WritingOptions.atomic)
        return outputURL
    }

    private static func compactPrompt(_ value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = oneLine.split(separator: " ")
        return words.count > 60 ? words.prefix(60).joined(separator: " ") : String(oneLine.prefix(360))
    }

    private static func enhancedPrompt(_ value: String) -> String {
        let base = compactPrompt(value)
        let normalized = base.lowercased()
        let humanTerms = ["person", "people", "human", "man", "woman", "boy", "girl", "child", "portrait", "face"]
        let animalTerms = ["animal", "dog", "cat", "horse", "bird", "rabbit", "tiger", "lion", "bear", "fox", "wolf"]
        if humanTerms.contains(where: normalized.contains) {
            return base + ", balanced composition, natural body proportions, anatomically coherent limbs, symmetrical eyes, detailed face"
        }
        if animalTerms.contains(where: normalized.contains) {
            return base + ", balanced composition, natural species anatomy, coherent legs and paws, symmetrical eyes, detailed face"
        }
        return base + ", balanced composition, clear subject separation, coherent perspective"
    }

    private static func negativePrompt(for prompt: String) -> String {
        let common = "low quality, blurry, pixelated, distorted perspective, duplicate subject, cropped subject, watermark, signature, text artifacts"
        let normalized = prompt.lowercased()
        if normalized.contains("species anatomy") {
            return common + ", mutated animal, malformed body, extra legs, missing legs, fused paws, distorted muzzle, multiple tails, multiple heads, asymmetrical eyes"
        }
        if normalized.contains("anatom") || normalized.contains("body proportions") {
            return common + ", deformed, disfigured, malformed anatomy, extra limbs, missing limbs, fused limbs, extra fingers, malformed hands, twisted legs, multiple heads, asymmetrical eyes, distorted face, long neck"
        }
        return common
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
