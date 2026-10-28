import Foundation
import AVFoundation
import Accelerate
import CoreML

// Shared by the iOS adapter and the bounded Mac recording worker.
public enum RecordingCoreMLInference {
    public static func run(audioURL: URL, speakerRoot: URL?, emotionRoot: URL?) throws -> (vector: [Float]?, state: RecordingVoiceState, score: Double?, emotion: String?, models: String) {
        let samples = try waveform(audioURL)
        guard samples.count >= 32000 else { throw PointVerseError.audioDecodeFailed }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        guard energy > 0.0001 else { throw PointVerseError.audioDecodeFailed }
        var vector: [Float]?
        var state = RecordingVoiceState.unknown
        var emotion: String?
        var score: Double?
        var models: [String] = []
        if let root = speakerRoot {
            vector = try autoreleasepool {
                let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
                let model = try MLModel(contentsOf: root.appending(path: "CamPlusPlus.mlmodelc"), configuration: config)
                let mel = try fbank(samples)
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel_features": mel]))
                guard let values = output.featureValue(for: "embedding")?.multiArrayValue, values.count == 192 else { throw PointVerseError.invalidModelOutput }
                let valuesArray = (0..<192).map { values[$0].floatValue }
                let norm = sqrt(valuesArray.reduce(Float(0)) { $0 + $1 * $1 })
                guard norm > 0, norm.isFinite else { throw PointVerseError.invalidModelOutput }
                return valuesArray.map { $0 / norm }
            }
            models.append("CAM++@" + "c3cbd83f0c1028cf753b3e3e67639854218206a1")
        }
        if let root = emotionRoot {
            (state, score, emotion) = try autoreleasepool {
                let preConfig = MLModelConfiguration(); preConfig.computeUnits = .cpuOnly
                let pre = try MLModel(contentsOf: root.appending(path: "SenseVoicePreprocessor.mlmodelc"), configuration: preConfig)
                let wave = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
                for i in samples.indices { wave[i] = NSNumber(value: samples[i] * 32768) }
                let features = try pre.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": wave]))
                guard let input = features.featureValue(for: "features")?.multiArrayValue, input.shape.count == 3, input.shape[2].intValue == 560 else { throw PointVerseError.invalidModelOutput }
                let length = input.shape[1].intValue
                guard let bucket = [128, 256, 512, 1024, 1800].first(where: { $0 >= length }) else { throw PointVerseError.invalidModelOutput }
                let padded = try MLMultiArray(shape: [1, NSNumber(value: bucket), 560], dataType: .float32)
                for i in 0..<padded.count { padded[i] = i < input.count ? input[i] : 0 }
                func scalar(_ value: Int) throws -> MLMultiArray {
                    let array = try MLMultiArray(shape: [1], dataType: .int32); array[0] = NSNumber(value: value); return array
                }
                let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
                let model = try MLModel(contentsOf: root.appending(path: "SenseVoiceSmall_int8.mlmodelc"), configuration: config)
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["speech": padded, "speech_lengths": scalar(length), "language": scalar(0), "textnorm": scalar(15)]))
                guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue,
                      logits.shape.count == 3, logits.shape[2].intValue == 25055 else { throw PointVerseError.invalidModelOutput }
                let vocab = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appending(path: "vocab.json")))
                guard vocab.count == 25055 else { throw PointVerseError.invalidModelOutput }
                let names = ["NEUTRAL", "HAPPY", "SAD", "ANGRY", "FEARFUL", "DISGUSTED", "SURPRISED"]
                let candidates = vocab.enumerated().filter { names.contains($0.element.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")) }
                guard candidates.count == 7 else { throw PointVerseError.invalidModelOutput }
                var strongestEmotionID = 0
                var strongestValue = -Double.infinity
                for id in 0..<25055 {
                    let value = logits[[0, 1, NSNumber(value: id)]].doubleValue
                    guard value.isFinite else { throw PointVerseError.invalidModelOutput }
                    if value > strongestValue { strongestValue = value; strongestEmotionID = id }
                }
                guard candidates.contains(where: { $0.offset == strongestEmotionID }) else {
                    return (.unknown, nil, vocab[strongestEmotionID])
                }
                // Emotion is the second query token. Normalize across emotion
                // tokens only; this score is a model score, not calibrated truth.
                let values = candidates.map { logits[[0, 1, NSNumber(value: $0.offset)]].doubleValue }
                guard values.allSatisfy({ $0.isFinite }), let maximum = values.max() else { throw PointVerseError.invalidModelOutput }
                let probabilities = values.map { exp($0 - maximum) }
                let sum = probabilities.reduce(0, +)
                let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] })!
                let probability = probabilities[best] / sum
                let token = candidates[best].element
                let state: RecordingVoiceState = probability < 0.6 ? .unknown : token.contains("NEUTRAL") ? .calm : token.contains("SAD") ? .subdued : token.contains("FEARFUL") ? .tense : token.contains("HAPPY") || token.contains("ANGRY") || token.contains("SURPRISED") ? .animated : .unknown
                return (state, probability, token)
            }
            models.append("SenseVoiceSmall-INT8@" + "74bdbe74b2258f25b5400db72f6cbfbef7c74ded")
        }
        return (vector, state, score, emotion, models.joined(separator: " / "))
    }

    static func waveform(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw PointVerseError.audioDecodeFailed }
        var samples: [Float] = []
        while samples.count < 160000 {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                do {
                    try file.read(into: input, frameCount: 4096)
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch { state.pointee = .endOfStream; return nil }
            }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return Array(samples.prefix(160000))
    }

    // Kaldi-compatible 16k fbank: 25ms frame / 10ms shift, Povey window,
    // DC removal, 0.97 pre-emphasis, 512 FFT, 80 mel bins, utterance CMN.
    static func fbank(_ samples: [Float]) throws -> MLMultiArray {
        // The pinned export is fixed at [1, 500, 80], despite the model card's
        // variable-length description. Require five seconds rather than pad.
        let frames = 500
        guard samples.count >= 400 + (frames - 1) * 160 else { throw PointVerseError.audioDecodeFailed }
        let output = try MLMultiArray(shape: [1, NSNumber(value: frames), 80], dataType: .float16)
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { throw PointVerseError.audioDecodeFailed }
        defer { vDSP_destroy_fftsetup(setup) }
        func mel(_ hz: Double) -> Double { 1127 * log(1 + hz / 700) }
        let edges = (0..<82).map { mel(20) + (mel(8000) - mel(20)) * Double($0) / 81 }
        var means = [Double](repeating: 0, count: 80)
        for frame in 0..<frames {
            var real = [Float](repeating: 0, count: 512), imag = real
            let mean = samples[(frame * 160)..<(frame * 160 + 400)].reduce(0, +) / 400
            for i in 0..<400 {
                let value = (samples[frame * 160 + i] - mean) * 32768
                let previous = (samples[frame * 160 + max(0, i - 1)] - mean) * 32768
                real[i] = (value - 0.97 * previous) * Float(pow(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 399), 0.85))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in 0..<80 {
                var energy: Double = 0
                for k in 0..<256 {
                    let frequency = mel(Double(k) * 16000 / 512)
                    let weight = frequency <= edges[bin + 1] ? (frequency - edges[bin]) / (edges[bin + 1] - edges[bin]) : (edges[bin + 2] - frequency) / (edges[bin + 2] - edges[bin + 1])
                    if weight > 0 { energy += weight * Double(real[k] * real[k] + imag[k] * imag[k]) }
                }
                let value = log(max(energy, Double(Float.ulpOfOne)))
                output[frame * 80 + bin] = NSNumber(value: value); means[bin] += value
            }
        }
        for frame in 0..<frames {
            for bin in 0..<80 { let index = frame * 80 + bin; output[index] = NSNumber(value: output[index].doubleValue - means[bin] / Double(frames)) }
        }
        return output
    }
}

