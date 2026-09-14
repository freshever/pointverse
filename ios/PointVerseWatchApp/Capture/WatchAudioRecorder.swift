import AVFAudio
import Foundation

actor WatchAudioRecorder {
    struct Result: Sendable {
        let captureID: UUID
        let url: URL
        let durationMilliseconds: Int
    }

    private var recorder: AVAudioRecorder?
    private var captureID: UUID?

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
        guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        self.recorder = recorder
        self.captureID = captureID
    }

    func elapsedText() -> String {
        let seconds = min(60, Int(recorder?.currentTime ?? 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func stop() async throws -> Result {
        guard let recorder, let captureID else { throw CocoaError(.fileWriteUnknown) }
        let duration = Int(recorder.currentTime * 1_000)
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.captureID = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard duration > 0 else { throw CocoaError(.fileWriteUnknown) }
        return Result(captureID: captureID, url: url, durationMilliseconds: duration)
    }
}
