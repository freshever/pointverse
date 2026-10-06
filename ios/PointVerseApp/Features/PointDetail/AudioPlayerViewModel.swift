import AVFAudio
import Foundation
import PointVerseKit

@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    private var player: AVAudioPlayer?

    func prepare(url: URL) {
        guard player?.url != url else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            isReady = player.prepareToPlay()
            self.player = player
        } catch {
            isReady = false
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                if player.currentTime >= player.duration { player.currentTime = 0 }
                isPlaying = player.play()
            } catch {
                isPlaying = false
            }
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

@MainActor
final class NotePreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() { engine.attach(node) }

    func toggle(notes: [String]) {
        if isPlaying { stop(); return }
        let frequencies = notes.compactMap(Self.frequency)
        guard !frequencies.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            let noteDuration = 0.48
            let gapDuration = 0.06
            let framesPerNote = Int(sampleRate * noteDuration)
            let framesPerGap = Int(sampleRate * gapDuration)
            let totalFrames = frequencies.count * (framesPerNote + framesPerGap)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
                  let output = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(totalFrames)
            for index in 0..<totalFrames { output[index] = 0 }
            for (noteIndex, frequency) in frequencies.enumerated() {
                let offset = noteIndex * (framesPerNote + framesPerGap)
                for frame in 0..<framesPerNote {
                    let time = Double(frame) / sampleRate
                    let progress = Double(frame) / Double(framesPerNote)
                    let attack = min(1, progress / 0.06)
                    let release = min(1, (1 - progress) / 0.22)
                    let envelope = Float(min(attack, release))
                    // A soft fundamental plus two harmonics is clearer than a
                    // pure sine while remaining lightweight and fully local.
                    let phase = 2 * Double.pi * frequency * time
                    let sample = sin(phase) + 0.22 * sin(phase * 2) + 0.08 * sin(phase * 3)
                    output[offset + frame] = Float(sample) * envelope * 0.25
                }
            }
            if !engine.isRunning { try engine.start() }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.isPlaying = false
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
            node.play()
            isPlaying = true
        } catch {
            stop()
        }
    }

    func toggle(sequence: [DetectedNoteEvent]) {
        if isPlaying { stop(); return }
        let playable = sequence.compactMap { event -> (Double, Double, Double)? in
            guard let frequency = Self.frequency(note: event.note) else { return nil }
            return (frequency, max(0, event.startSeconds), min(3, max(0.12, event.durationSeconds)))
        }
        guard !playable.isEmpty else { return }
        play(events: playable)
    }

    private func play(events: [(frequency: Double, start: Double, duration: Double)]) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            let endTime = events.map { $0.start + $0.duration }.max() ?? 0
            let totalFrames = max(1, Int(sampleRate * (endTime + 0.08)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
                  let output = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(totalFrames)
            for index in 0..<totalFrames { output[index] = 0 }
            for event in events {
                let offset = Int(event.start * sampleRate)
                let frames = min(Int(event.duration * sampleRate), totalFrames - offset)
                guard frames > 0 else { continue }
                for frame in 0..<frames {
                    let time = Double(frame) / sampleRate
                    let progress = Double(frame) / Double(frames)
                    let envelope = Float(min(min(1, progress / 0.05), min(1, (1 - progress) / 0.12)))
                    let phase = 2 * Double.pi * event.frequency * time
                    let sample = sin(phase) + 0.22 * sin(phase * 2) + 0.08 * sin(phase * 3)
                    output[offset + frame] += Float(sample) * envelope * 0.25
                }
            }
            if !engine.isRunning { try engine.start() }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.isPlaying = false
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
            node.play(); isPlaying = true
        } catch { stop() }
    }

    func stop() {
        node.stop()
        engine.stop()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func frequency(note: String) -> Double? {
        let normalized = note.replacingOccurrences(of: "#", with: "♯")
        let names = ["C": 0, "C♯": 1, "D": 2, "D♯": 3, "E": 4, "F": 5,
                     "F♯": 6, "G": 7, "G♯": 8, "A": 9, "A♯": 10, "B": 11]
        guard let octaveCharacter = normalized.last,
              let octave = Int(String(octaveCharacter)) else { return nil }
        let name = String(normalized.dropLast())
        guard let pitchClass = names[name] else { return nil }
        let midi = (octave + 1) * 12 + pitchClass
        return 440 * pow(2, Double(midi - 69) / 12)
    }
}
