import AVFoundation
import CoreML
import Foundation
import PointVerseKit
import ZIPFoundation
import CryptoKit
import Accelerate
import Combine

enum RecordingModelKind: String, CaseIterable, Identifiable {
    case speaker, emotion
    var id: String { rawValue }
    var title: String { self == .speaker ? "CAM++ 声纹 · 约14 MB" : "SenseVoice 声音状态 · 约239 MB" }
    var repository: String { self == .speaker ? "aufklarer/CamPlusPlus-Speaker-CoreML" : "FluidInference/sensevoice-small-coreml" }
    var revision: String { self == .speaker ? "c3cbd83f0c1028cf753b3e3e67639854218206a1" : "74bdbe74b2258f25b5400db72f6cbfbef7c74ded" }
    var prefixes: [String] { self == .speaker ? ["CamPlusPlus.mlmodelc/"] : ["SenseVoicePreprocessor.mlmodelc/", "SenseVoiceSmall_int8.mlmodelc/", "vocab.json"] }
}

@MainActor
final class RecordingModelManager: ObservableObject {
    private static var sharedManagers: [String: RecordingModelManager] = [:]
    static func shared(rootURL: URL, executionGate: ModelExecutionGate) -> RecordingModelManager {
        let key = rootURL.standardizedFileURL.path
        if let existing = sharedManagers[key] { return existing }
        let manager = RecordingModelManager(rootURL: rootURL, executionGate: executionGate)
        sharedManagers[key] = manager
        return manager
    }

    @Published private(set) var downloading: RecordingModelKind?
    @Published private(set) var progress: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var phase = ""
    @Published private(set) var pausedKind: RecordingModelKind?
    @Published private(set) var error: String?
    @Published private(set) var installed: Set<RecordingModelKind> = []
    private let root: URL
    private let componentRegistry: ModelRegistry
    let executionGate: ModelExecutionGate
    private var componentManagers: [String: ModelDownloadManager] = [:]
    private var activeComponent: ModelDownloadManager?
    private var progressObserver: AnyCancellable?
    private var packageTask: Task<Void, Never>?

    init(rootURL: URL, executionGate: ModelExecutionGate) {
        root = rootURL.appending(path: "recording-models")
        componentRegistry = ModelRegistry(rootURL: root)
        self.executionGate = executionGate
        refresh()
        // Recreate the same background sessions before iOS delivers events.
        for kind in RecordingModelKind.allCases {
            if let data = try? Data(contentsOf: metadataURL(kind)),
               let repo = try? JSONDecoder().decode(Repo.self, from: data),
               let files = try? validatedFiles(repo, kind: kind) {
                for file in files { _ = componentManager(manifest(file, kind: kind)) }
            }
            if !installed.contains(kind), let state = try? String(contentsOf: pendingURL(kind), encoding: .utf8) {
                if state == "active", AppNetworkPolicy.allowsModelDownloads() { Task { await download(kind) } }
                else { pausedKind = kind }
            }
        }
    }

    func modelRoot(_ kind: RecordingModelKind) -> URL { root.appending(path: kind.rawValue + "-" + kind.revision) }
    private func metadataURL(_ kind: RecordingModelKind) -> URL { root.appending(path: kind.rawValue + "-" + kind.revision + ".manifest.json") }
    private func pendingURL(_ kind: RecordingModelKind) -> URL { root.appending(path: kind.rawValue + ".pending") }
    func refresh() {
        installed = Set(RecordingModelKind.allCases.filter { FileManager.default.fileExists(atPath: modelRoot($0).appending(path: "ready.json").path) })
    }

    private struct Repo: Codable {
        let sha: String
        let siblings: [File]
        struct File: Codable {
            let rfilename: String
            let blobId: String?
            let size: Int64
            let lfs: LFS?
            struct LFS: Codable { let sha256: String; let size: Int64 }
        }
    }

    private func validatedFiles(_ repo: Repo, kind: RecordingModelKind) throws -> [Repo.File] {
        guard repo.sha == kind.revision else { throw PointVerseError.invalidModelOutput }
        let files = repo.siblings.filter { file in kind.prefixes.contains { file.rfilename == $0 || file.rfilename.hasPrefix($0) } }
        guard !files.isEmpty, files.count <= 64 else { throw PointVerseError.invalidModelOutput }
        for file in files {
            let parts = file.rfilename.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(".."), !parts.contains("."), !parts.contains(""),
                  file.size > 0, file.size <= 1_000_000_000,
                  file.blobId != nil || file.lfs != nil else { throw PointVerseError.invalidModelOutput }
        }
        for prefix in kind.prefixes {
            let required = prefix.hasSuffix("/") ? ["coremldata.bin", "model.mil", "weights/weight.bin"].map { prefix + $0 } : [prefix]
            guard required.allSatisfy({ name in files.contains(where: { $0.rfilename == name }) }) else { throw PointVerseError.invalidModelOutput }
        }
        return files
    }

    private func manifest(_ file: Repo.File, kind: RecordingModelKind) -> ModelManifest {
        let pathHash = SHA256.hash(data: Data(file.rfilename.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let id = "recording-" + kind.rawValue + "-" + String(kind.revision.prefix(12)) + "-" + pathHash
        let path = "\(kind.repository)/resolve/\(kind.revision)/\(file.rfilename)"
        return ModelManifest(id: id, revision: kind.revision, filename: id + ".file",
            downloadURL: URL(string: "https://huggingface.co/" + path)!,
            mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/" + path)!],
            displayByteCount: file.lfs?.size ?? file.size, sha256: file.lfs?.sha256 ?? "",
            license: kind == .speaker ? "Apache-2.0" : "SenseVoice upstream",
            minimumFreeDiskBytes: max(20_000_000, file.size + 20_000_000),
            gitBlobSHA1: file.lfs == nil ? file.blobId : nil)
    }

    private func componentManager(_ manifest: ModelManifest) -> ModelDownloadManager {
        if let existing = componentManagers[manifest.id] { return existing }
        let manager = ModelDownloadManager(registry: componentRegistry, manifest: manifest)
        componentManagers[manifest.id] = manager
        return manager
    }

    private func metadata(_ kind: RecordingModelKind) async throws -> Data {
        if let data = try? Data(contentsOf: metadataURL(kind)),
           let repo = try? JSONDecoder().decode(Repo.self, from: data),
           (try? validatedFiles(repo, kind: kind)) != nil { return data }
        var lastError: any Error = PointVerseError.modelNotInstalled
        for host in ["hf-mirror.com", "huggingface.co"] {
            for _ in 0..<2 {
                try Task.checkCancellation()
                guard AppNetworkPolicy.allowsModelDownloads() else { throw NetworkPolicyError.downloadsDisabled }
                phase = "读取模型清单 · \(host)"
                var request = URLRequest(url: URL(string: "https://\(host)/api/models/\(kind.repository)/revision/\(kind.revision)?blobs=true")!)
                request.timeoutInterval = 25
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw NSError(domain: "模型清单HTTP", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    let repo = try JSONDecoder().decode(Repo.self, from: data)
                    _ = try validatedFiles(repo, kind: kind)
                    try data.write(to: metadataURL(kind), options: .atomic)
                    return data
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = error
                }
            }
        }
        throw lastError
    }

    func pause() {
        guard let kind = downloading else { return }
        pausedKind = kind
        phase = "正在暂停并保存断点…"
        try? "paused".write(to: pendingURL(kind), atomically: true, encoding: .utf8)
        activeComponent?.cancel()
        packageTask?.cancel()
    }

    func download(_ kind: RecordingModelKind) async {
        guard AppNetworkPolicy.allowsModelDownloads() else { error = NetworkPolicyError.downloadsDisabled.localizedDescription; return }
        guard downloading == nil, !installed.contains(kind) else { return }
        downloading = kind; error = nil; progress = 0; receivedBytes = 0; totalBytes = 0; pausedKind = nil
        let job = Task { await performDownload(kind) }
        packageTask = job
        await job.value
        packageTask = nil; activeComponent = nil; progressObserver = nil; downloading = nil
    }

    private func performDownload(_ kind: RecordingModelKind) async {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = root
            var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
            try excluded.setResourceValues(resourceValues)
            let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > (kind == .speaker ? 100_000_000 : 700_000_000) else { throw PointVerseError.insufficientDiskSpace }
            try "active".write(to: pendingURL(kind), atomically: true, encoding: .utf8)
            let data = try await metadata(kind)
            try Task.checkCancellation()
            let repo = try JSONDecoder().decode(Repo.self, from: data)
            let files = try validatedFiles(repo, kind: kind)
            totalBytes = files.reduce(0) { $0 + ($1.lfs?.size ?? $1.size) }
            let staging = root.appending(path: kind.rawValue + "-" + kind.revision + ".partial")
            var completed: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                let descriptor = manifest(file, kind: kind)
                let target = staging.appending(path: file.rfilename)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                phase = "校验已有文件 · \(file.rfilename)"
                // Reuse complete files written by build 19's prototype downloader.
                if (try? await componentRegistry.verifyFile(at: target, manifest: descriptor)) != nil {
                    completed += descriptor.displayByteCount
                    receivedBytes = completed; progress = Double(completed) / Double(max(1, totalBytes))
                    continue
                }
                let manager = componentManager(descriptor)
                activeComponent = manager
                let base = completed
                progressObserver = manager.$state.sink { [weak self] state in
                    guard let self else { return }
                    let fraction: Double
                    switch state {
                    case .downloading(let value): fraction = value; self.phase = "下载 · \(file.rfilename)"
                    case .verifying: fraction = 1; self.phase = "校验 · \(file.rfilename)"
                    case .installed: fraction = 1
                    default: return
                    }
                    self.receivedBytes = base + Int64(Double(descriptor.displayByteCount) * fraction)
                    self.progress = min(1, Double(self.receivedBytes) / Double(max(1, self.totalBytes)))
                }
                let installedFile = try await manager.downloadAndWait()
                try Task.checkCancellation()
                phase = "安装 · \(file.rfilename)"
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: installedFile, to: target)
                try await componentRegistry.verifyFile(at: target, manifest: descriptor)
                completed += descriptor.displayByteCount
                receivedBytes = completed; progress = Double(completed) / Double(max(1, totalBytes))
                progressObserver = nil; activeComponent = nil
            }
            try Task.checkCancellation()
            phase = "完成安装"
            try data.write(to: staging.appending(path: "ready.json"), options: .atomic)
            let destination = modelRoot(kind)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw PointVerseError.invalidModelOutput }
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: pendingURL(kind))
            refresh()
            // Drop verified component copies; the installed bundle owns the files.
            for file in files { try? await componentRegistry.remove(manifest(file, kind: kind)) }
            phase = "已下载"; progress = 1
        } catch {
            if Task.isCancelled || (error as? PointVerseError) == .cancelled {
                pausedKind = kind; phase = "已暂停，可继续下载"
                try? "paused".write(to: pendingURL(kind), atomically: true, encoding: .utf8)
            } else {
                let detail = activeComponent?.lastErrorDescription ?? (error as? PointVerseError)?.rawValue ?? error.localizedDescription
                self.error = "下载失败：\(detail)。重试将优先恢复断点，并自动尝试镜像和官方源。"
                phase = "下载失败"
                // Do not automatically loop a failed package on every launch.
                try? "paused".write(to: pendingURL(kind), atomically: true, encoding: .utf8)
                pausedKind = kind
            }
        }
    }

    func recognize(audioURL: URL) async throws -> (vector: [Float]?, state: RecordingVoiceState, score: Double?, emotion: String?, models: String) {
        guard !installed.isEmpty else { throw PointVerseError.modelNotInstalled }
        let speakerRoot = installed.contains(.speaker) ? modelRoot(.speaker) : nil
        let emotionRoot = installed.contains(.emotion) ? modelRoot(.emotion) : nil
        await executionGate.acquire()
        do {
            let result = try await Task.detached(priority: .utility) {
                try RecordingCoreMLInference.run(audioURL: audioURL, speakerRoot: speakerRoot, emotionRoot: emotionRoot)
            }.value
            await executionGate.release()
            return result
        } catch { await executionGate.release(); throw error }
    }
}

/// Runs bounded-memory acoustic analysis. CLAP is deliberately represented by
/// an optional analyzer so recordings remain usable while its Core ML assets
/// are not installed.
actor AudioUnderstandingService {
    static let didChangeNotification = Notification.Name("PointVerseAudioUnderstandingDidChange")

    private let repository: any PointRepository
    private let blobStore: any AudioBlobStoring
    private let transcriptionService: TranscriptionService
    private let clapEncoder: CLAPAudioEncoder

    init(repository: any PointRepository, blobStore: any AudioBlobStoring,
         transcriptionService: TranscriptionService, registry: ModelRegistry,
         rootURL: URL, executionGate: ModelExecutionGate) {
        self.repository = repository
        self.blobStore = blobStore
        self.transcriptionService = transcriptionService
        self.clapEncoder = CLAPAudioEncoder(registry: registry, rootURL: rootURL,
                                            executionGate: executionGate)
    }

    func understand(pointID: PointID, languageIdentifier: String) async throws {
        let detail = try await repository.pointDetail(id: pointID)
        guard let path = detail.audioRelativePath else { throw PointVerseError.audioDecodeFailed }
        let url = try await blobStore.url(for: path)
        let features = try await Task.detached(priority: .utility) { try Self.extractFeatures(url: url) }.value
        let clapResult = try? await clapEncoder.encode(audioURL: url)

        // Existing transcription is evidence of vocals. If it is absent, try
        // the selected local Whisper model; failure is valid for ambient audio.
        var lyric = detail.effectiveTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lyric.isEmpty, let model = ModelSelection.speechModels.first {
            try? await transcriptionService.transcribeCandidate(pointID: pointID, modelID: model.id)
            lyric = (try? await repository.pointDetail(id: pointID))?.effectiveTranscript ?? ""
        }
        let hasVoice = !lyric.isEmpty
        var tags = features.tags
        if hasVoice { tags.append("人声") }

        let value = AudioUnderstanding(
            durationSeconds: features.duration, loudnessDB: features.loudness,
            bpm: features.bpm, dominantPitchHz: features.pitch,
            detectedNotes: features.notes, estimatedKey: features.key,
            noteSequence: features.sequence,
            rhythmStrength: features.rhythmStrength,
            semanticTags: Array(Set(tags)).sorted(), clapModelID: clapResult?.modelID, hasVoice: hasVoice
        )
        try await repository.saveAudioUnderstanding(pointID: pointID, value: value,
                                                    semanticVector: clapResult?.vector)
        _ = await transcriptionService.deriveTitle(pointID: pointID, languageIdentifier: languageIdentifier)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didChangeNotification,
                                            object: pointID.rawValue.uuidString)
        }
    }

    private struct Features: Sendable {
        let duration: Double
        let loudness: Double
        let bpm: Double?
        let pitch: Double?
        let rhythmStrength: Double
        let tags: [String]
        let notes: [String]
        let key: String?
        let sequence: [DetectedNoteEvent]
    }

    nonisolated private static func extractFeatures(url: URL) throws -> Features {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let chunkFrames: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw PointVerseError.audioDecodeFailed
        }
        var energy = 0.0
        var sampleCount = 0
        var crossings = 0
        var previous: Float = 0
        var envelope: [Double] = []
        let envelopeStride = max(1, Int(sampleRate / 100))
        var envelopeEnergy = 0.0
        var envelopeSamples = 0
        var pitchSamples: [Float] = []
        let pitchStride = max(1, Int(sampleRate / 8_000))
        let pitchSampleRate = sampleRate / Double(pitchStride)
        let maximumPitchSamples = Int(pitchSampleRate * 20)
        pitchSamples.reserveCapacity(maximumPitchSamples)
        var absoluteSampleIndex = 0

        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let values = channels[0]
            for index in 0..<Int(buffer.frameLength) {
                let sample = values[index]
                if pitchSamples.count < maximumPitchSamples, absoluteSampleIndex % pitchStride == 0 {
                    pitchSamples.append(sample)
                }
                absoluteSampleIndex += 1
                energy += Double(sample * sample)
                sampleCount += 1
                if (sample >= 0) != (previous >= 0), abs(sample - previous) > 0.01 { crossings += 1 }
                previous = sample
                envelopeEnergy += Double(sample * sample)
                envelopeSamples += 1
                if envelopeSamples == envelopeStride {
                    envelope.append(sqrt(envelopeEnergy / Double(envelopeSamples)))
                    envelopeEnergy = 0; envelopeSamples = 0
                }
            }
        }
        guard sampleCount > 0 else { throw PointVerseError.audioDecodeFailed }
        let rms = sqrt(energy / Double(sampleCount))
        let loudness = 20 * log10(max(rms, 0.000_001))
        let duration = Double(sampleCount) / sampleRate
        let pitchEstimate = Double(crossings) * sampleRate / (2 * Double(sampleCount))
        let pitch = (55...1_200).contains(pitchEstimate) ? pitchEstimate : nil
        let tempo = estimateTempo(envelope)
        let tonal = estimateNotes(samples: pitchSamples, sampleRate: pitchSampleRate)
        var tags: [String] = [loudness > -18 ? "响亮" : loudness < -42 ? "安静" : "中等响度"]
        if tempo.strength > 0.18 { tags.append("节奏明显") }
        else { tags.append("环境声") }
        if let bpm = tempo.bpm { tags.append(bpm >= 120 ? "快速" : bpm < 80 ? "舒缓" : "中速") }
        if !tonal.notes.isEmpty { tags.append("有调性") }
        return Features(duration: duration, loudness: loudness, bpm: tempo.bpm,
                        pitch: tonal.dominantHz ?? pitch, rhythmStrength: tempo.strength, tags: tags,
                        notes: tonal.notes, key: tonal.key, sequence: tonal.sequence)
    }

    nonisolated private static func estimateTempo(_ envelope: [Double]) -> (bpm: Double?, strength: Double) {
        guard envelope.count > 300 else { return (nil, 0) }
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        let centered = envelope.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 0.000_001 else { return (nil, 0) }
        var bestLag = 0
        var best = 0.0
        // Envelope rate is 100 Hz; 30...150 samples represents 200...40 BPM.
        for lag in 30...150 {
            var score = 0.0
            for index in lag..<centered.count { score += centered[index] * centered[index - lag] }
            score /= energy
            if score > best { best = score; bestLag = lag }
        }
        guard bestLag > 0, best > 0.08 else { return (nil, max(0, best)) }
        return (6_000 / Double(bestLag), min(1, best))
    }

    nonisolated private static func estimateNotes(samples: [Float], sampleRate: Double)
        -> (notes: [String], key: String?, dominantHz: Double?, sequence: [DetectedNoteEvent]) {
        let frameSize = 1_024, hop = 512
        guard samples.count >= frameSize else { return ([], nil, nil, []) }
        let minimumLag = max(2, Int(sampleRate / 1_000))
        let maximumLag = min(frameSize / 2, Int(sampleRate / 55))
        var midiCounts: [Int: Int] = [:]
        var frequencySum: [Int: Double] = [:]
        var frameNotes: [Int?] = []
        var start = 0
        while start + frameSize <= samples.count {
            let frame = samples[start..<(start + frameSize)]
            let rms = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(frameSize))
            if rms > 0.012 {
                var bestLag = 0, bestCorrelation = 0.0
                for lag in minimumLag...maximumLag {
                    var correlation = 0.0, leftEnergy = 0.0, rightEnergy = 0.0
                    for index in 0..<(frameSize - lag) {
                        let left = Double(samples[start + index])
                        let right = Double(samples[start + index + lag])
                        correlation += left * right; leftEnergy += left * left; rightEnergy += right * right
                    }
                    let normalized = correlation / sqrt(max(0.000_000_1, leftEnergy * rightEnergy))
                    if normalized > bestCorrelation { bestCorrelation = normalized; bestLag = lag }
                }
                if bestLag > 0, bestCorrelation > 0.72 {
                    let frequency = sampleRate / Double(bestLag)
                    let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
                    if (24...108).contains(midi) {
                        midiCounts[midi, default: 0] += 1
                        frequencySum[midi, default: 0] += frequency
                        frameNotes.append(midi)
                    } else {
                        frameNotes.append(nil)
                    }
                } else {
                    frameNotes.append(nil)
                }
            } else {
                frameNotes.append(nil)
            }
            start += hop
        }
        let ranked = midiCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        guard let dominant = ranked.first else { return ([], nil, nil, []) }
        let threshold = max(2, dominant.value / 5)
        let selected = Set(ranked.filter { $0.value >= threshold }.prefix(12).map(\.key))
        let sequence = noteEvents(frameNotes: frameNotes, hopSeconds: Double(hop) / sampleRate)
        var seen = Set<Int>()
        let orderedMidi = frameNotes.compactMap { $0 }.filter { selected.contains($0) && seen.insert($0).inserted }
        let notes = orderedMidi.map(noteName)
        let dominantHz = frequencySum[dominant.key].map { $0 / Double(dominant.value) }
        return (notes, estimateKey(midiCounts), dominantHz, sequence)
    }

    nonisolated private static func noteEvents(frameNotes: [Int?], hopSeconds: Double) -> [DetectedNoteEvent] {
        // Remove isolated one-frame octave glitches with a three-frame median.
        var smoothed = frameNotes
        if frameNotes.count >= 3 {
            for index in 1..<(frameNotes.count - 1) {
                let values = [frameNotes[index - 1], frameNotes[index], frameNotes[index + 1]].compactMap { $0 }.sorted()
                if values.count >= 2 { smoothed[index] = values[values.count / 2] }
            }
        }
        var events: [DetectedNoteEvent] = []
        var current: Int?, startFrame = 0
        func appendEvent(note: Int?, endFrame: Int) {
            guard let note else { return }
            let duration = Double(endFrame - startFrame) * hopSeconds
            guard duration >= 0.12 else { return }
            events.append(.init(note: noteName(note), startSeconds: Double(startFrame) * hopSeconds,
                                durationSeconds: duration))
        }
        for (index, note) in smoothed.enumerated() {
            if note != current {
                appendEvent(note: current, endFrame: index)
                current = note; startFrame = index
            }
        }
        appendEvent(note: current, endFrame: smoothed.count)
        return Array(events.prefix(64))
    }

    nonisolated private static func noteName(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[(midi % 12 + 12) % 12] + String(midi / 12 - 1)
    }

    nonisolated private static func estimateKey(_ midiCounts: [Int: Int]) -> String? {
        guard midiCounts.values.reduce(0, +) >= 4 else { return nil }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        var histogram = [Double](repeating: 0, count: 12)
        for (midi, count) in midiCounts { histogram[(midi % 12 + 12) % 12] += Double(count) }
        var bestRoot = 0, bestIsMinor = false, bestScore = -Double.infinity
        for root in 0..<12 {
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let score = (0..<12).reduce(0.0) { $0 + histogram[($1 + root) % 12] * profile[$1] }
                if score > bestScore { bestScore = score; bestRoot = root; bestIsMinor = isMinor }
            }
        }
        return names[bestRoot] + (bestIsMinor ? " 小调" : " 大调")
    }
}

private actor CLAPAudioEncoder {
    struct Result: Sendable { let vector: [Float]; let modelID: String }
    private final class SendableModel: @unchecked Sendable {
        let value: MLModel
        init(_ value: MLModel) { self.value = value }
    }

    private let registry: ModelRegistry
    private let rootURL: URL
    private let executionGate: ModelExecutionGate
    private var model: SendableModel?

    init(registry: ModelRegistry, rootURL: URL, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.rootURL = rootURL
        self.executionGate = executionGate
    }

    func encode(audioURL: URL) async throws -> Result {
        let manifest = ModelManifest.gridshiftCLAPMusicCoreML
        guard await registry.isInstalled(manifest) else { throw PointVerseError.modelNotInstalled }
        await executionGate.acquire()
        defer { Task { await executionGate.release() } }
        let loaded = try await loadModel(manifest: manifest)
        let samples = try await Task.detached(priority: .utility) {
            try Self.resampledMono48k(url: audioURL, maximumSeconds: 60)
        }.value
        let windows = Self.windows(from: samples)
        guard !windows.isEmpty else { throw PointVerseError.audioDecodeFailed }
        var pooled = [Float](repeating: 0, count: 512)
        for window in windows {
            let input = try MLMultiArray(shape: [1, 480_000], dataType: .float32)
            let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: 480_000)
            window.withUnsafeBufferPointer { source in
                pointer.update(from: source.baseAddress!, count: 480_000)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            guard let output = try await loaded.value.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue,
                  output.count == 512 else { throw PointVerseError.invalidModelOutput }
            for index in pooled.indices { pooled[index] += output[index].floatValue }
        }
        let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { throw PointVerseError.invalidModelOutput }
        pooled = pooled.map { $0 / norm }
        return Result(vector: pooled, modelID: manifest.id)
    }

    private func loadModel(manifest: ModelManifest) async throws -> SendableModel {
        if let model { return model }
        let compiled = rootURL.appending(path: "audio-understanding/GridshiftCLAP.mlmodelc",
                                         directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let archive = await registry.installedURL(for: manifest)
            let folder = rootURL.appending(path: "audio-understanding/clap-package", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archive, to: folder)
            guard let package = Self.findPackage(in: folder) else { throw PointVerseError.modelNotInstalled }
            let temporary = try await Task.detached(priority: .utility) { try MLModel.compileModel(at: package) }.value
            try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temporary, to: compiled)
            try? FileManager.default.removeItem(at: folder)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let loaded = try MLModel(contentsOf: compiled, configuration: configuration)
        let sendable = SendableModel(loaded)
        model = sendable
        return sendable
    }

    nonisolated private static func findPackage(in folder: URL) -> URL? {
        if folder.pathExtension == "mlpackage" { return folder }
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                               includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "mlpackage" { return url }
        return nil
    }

    nonisolated private static func windows(from samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        let size = 480_000
        if samples.count <= size {
            var window = samples
            if samples.count < 24_000 {
                while window.count < min(24_000, size) { window.append(contentsOf: samples) }
            }
            window += repeatElement(0, count: max(0, size - window.count))
            return [Array(window.prefix(size))]
        }
        let desired = min(6, Int(ceil(Double(samples.count) / Double(size))))
        let maximumStart = samples.count - size
        return (0..<desired).map { index in
            let start = desired == 1 ? 0 : Int(Double(maximumStart) * Double(index) / Double(desired - 1))
            return Array(samples[start..<(start + size)])
        }
    }

    nonisolated private static func resampledMono48k(url: URL, maximumSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PointVerseError.audioDecodeFailed
        }
        let maximumSamples = Int(48_000 * maximumSeconds)
        var result: [Float] = []
        result.reserveCapacity(min(maximumSamples, Int(Double(file.length) * 48_000 / inputFormat.sampleRate)))
        var reachedEnd = false
        while !reachedEnd, result.count < maximumSamples {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
                throw PointVerseError.audioDecodeFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard !reachedEnd else { inputStatus.pointee = .endOfStream; return nil }
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: requested) else {
                    inputStatus.pointee = .noDataNow; return nil
                }
                do {
                    try file.read(into: input, frameCount: requested)
                    if input.frameLength == 0 { reachedEnd = true; inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    reachedEnd = true; inputStatus.pointee = .endOfStream; return nil
                }
            }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                let count = min(Int(output.frameLength), maximumSamples - result.count)
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            }
            if status == .endOfStream { reachedEnd = true }
            if status == .error { throw PointVerseError.audioDecodeFailed }
        }
        let peak = result.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 { for index in result.indices { result[index] /= peak } }
        return result
    }
}
