import AVFAudio
import Foundation

actor WatchAudioRecorder {
    struct Activity: Sendable {
        let durationMilliseconds: Int
        let hasDetectedVoice: Bool
        let silenceMilliseconds: Int

        var shouldAutoStop: Bool { hasDetectedVoice && silenceMilliseconds >= 3_000 }
    }

    struct Result: Sendable {
        let captureID: UUID
        let url: URL
        let durationMilliseconds: Int
    }

    private var recorder: AVAudioRecorder?
    private var captureID: UUID?
    private var detectedVoice = false
    private var lastVoiceTime: TimeInterval?
    private static let voiceThreshold: Float = -45
    private static let minimumDurationMilliseconds = 1_000

    func start(captureID: UUID, url: URL) async throws {
        let session = AVAudioSession.sharedInstance()
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw CocoaError(.userCancelled) }
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        self.recorder = recorder
        self.captureID = captureID
        detectedVoice = false
        lastVoiceTime = nil
    }

    func activity() -> Activity {
        guard let recorder else {
            return Activity(durationMilliseconds: 0, hasDetectedVoice: false, silenceMilliseconds: 0)
        }
        recorder.updateMeters()
        let currentTime = recorder.currentTime
        if recorder.averagePower(forChannel: 0) >= Self.voiceThreshold {
            detectedVoice = true
            lastVoiceTime = currentTime
        }
        return Activity(
            durationMilliseconds: Int(currentTime * 1_000),
            hasDetectedVoice: detectedVoice,
            silenceMilliseconds: lastVoiceTime.map { max(0, Int((currentTime - $0) * 1_000)) } ?? 0
        )
    }

    func stop() async throws -> Result {
        guard let recorder, let captureID else { throw CocoaError(.fileWriteUnknown) }
        let duration = Int(recorder.currentTime * 1_000)
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.captureID = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard duration >= Self.minimumDurationMilliseconds else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        guard detectedVoice else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileReadCorruptFile)
        }
        return Result(captureID: captureID, url: url, durationMilliseconds: duration)
    }
}
