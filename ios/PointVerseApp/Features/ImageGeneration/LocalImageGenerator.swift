import CoreML
import Foundation
import PointVerseKit
import QwenAdapter
import StableDiffusion
import UIKit
import ZIPFoundation

struct GeneratedImageArtifact: Sendable {
    let url: URL
    let modelID: String
}

struct GeneratedImageWorkflowResult: Sendable {
    let artifact: GeneratedImageArtifact
    let prompt: String
}

/// One shared image-generation pipeline for every screen and every provider.
/// The selected language route prepares the English prompt; the selected image
/// route consumes that exact prompt. Local and network image providers therefore
/// differ only in the final rendering implementation.
actor ImageGenerationWorkflow {
    private let promptTranslator: QwenTitleGenerator
    private let imageGenerator: LocalImageGenerator

    init(promptTranslator: QwenTitleGenerator, imageGenerator: LocalImageGenerator) {
        self.promptTranslator = promptTranslator
        self.imageGenerator = imageGenerator
    }

    func generate(
        source: String,
        localeIdentifier: String,
        promptHandler: @escaping @MainActor @Sendable (String) -> Void,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> GeneratedImageWorkflowResult {
        let prompt = try await promptTranslator.translateImagePromptToEnglish(
            source,
            localeIdentifier: localeIdentifier
        )
        await promptHandler(prompt)
        let artifact = try await imageGenerator.generate(prompt: prompt, progressHandler: progressHandler)
        return GeneratedImageWorkflowResult(artifact: artifact, prompt: prompt)
    }
}

actor LocalImageGenerator {
    private let registry: ModelRegistry
    private let rootURL: URL
    private let executionGate: ModelExecutionGate

    init(registry: ModelRegistry, rootURL: URL, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.rootURL = rootURL
        self.executionGate = executionGate
    }

    func generate(prompt: String, progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> GeneratedImageArtifact {
        await executionGate.acquire()
        defer { Task { await executionGate.release() } }
        if let networkModel = try selectedNetworkModel() {
            return try await generateRemotely(prompt: prompt, model: networkModel, progressHandler: progressHandler)
        }
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
        return GeneratedImageArtifact(url: outputURL, modelID: manifest.id)
    }

    private func selectedNetworkModel(defaults: UserDefaults = .standard) throws -> ExternalLanguageModel? {
        guard let selectionID = defaults.string(forKey: "selectedExternalModel.imageGeneration"),
              selectionID != "local" else { return nil }
        guard let model = ExternalLanguageModelStore.load(defaults: defaults).first(where: {
            $0.selectionID == selectionID && $0.kind == .openAICompatible && $0.supports(.imageGeneration)
        }) else { throw ExternalModelConnectionError.invalidConfiguration }
        return model
    }

    private func generateRemotely(
        prompt: String,
        model: ExternalLanguageModel,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> GeneratedImageArtifact {
        guard ExternalModelPrivacyApprovalStore.isApproved(model.id),
              let baseURL = URL(string: model.baseURL ?? ""),
              let remoteModel = model.remoteModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteModel.isEmpty else { throw ExternalModelConnectionError.invalidConfiguration }

        let endpoint: URL
        if baseURL.path.hasSuffix("/images") || baseURL.path.hasSuffix("/images/generations") {
            endpoint = baseURL
        } else if model.provider == .openRouter {
            endpoint = baseURL.appending(path: "images")
        } else {
            endpoint = baseURL.appending(path: "images/generations")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ExternalModelAPIKeyStore.load(modelID: model.id), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if model.provider == .openRouter { request.setValue("PointVerse", forHTTPHeaderField: "X-Title") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": remoteModel,
            "prompt": prompt,
            "n": 1,
            "output_format": "png"
        ])
        progressHandler(0.05)
        let (data, response) = try await NetworkModelRequestExecutor.perform(request)
        guard let http = response as? HTTPURLResponse else { throw ExternalModelConnectionError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "未知错误"
            throw ExternalModelConnectionError.server(status: http.statusCode, message: String(message.prefix(300)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["data"] as? [[String: Any]])?.first else {
            throw ExternalModelConnectionError.invalidResponse
        }
        let imageData: Data
        if let encoded = first["b64_json"] as? String, let decoded = Data(base64Encoded: encoded) {
            imageData = decoded
        } else if let value = first["url"] as? String, let url = URL(string: value) {
            var downloadRequest = URLRequest(url: url)
            downloadRequest.timeoutInterval = 120
            let (downloaded, imageResponse) = try await NetworkModelRequestExecutor.perform(downloadRequest)
            guard (imageResponse as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) != false else {
                throw ExternalModelConnectionError.invalidResponse
            }
            imageData = downloaded
        } else {
            throw ExternalModelConnectionError.invalidResponse
        }
        guard UIImage(data: imageData) != nil else { throw PointVerseError.invalidModelOutput }
        let outputDirectory = rootURL.appending(path: "generated-images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appending(path: UUID().uuidString + ".png")
        try imageData.write(to: outputURL, options: .atomic)
        progressHandler(1)
        let responseModel = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedModel = responseModel?.isEmpty == false ? responseModel! : "requested:\(remoteModel)"
        return GeneratedImageArtifact(url: outputURL, modelID: recordedModel)
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
