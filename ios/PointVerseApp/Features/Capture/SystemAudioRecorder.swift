import AVFAudio
import Foundation
import PointVerseKit

actor SystemAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?

    func start(at temporaryURL: URL) async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw PointVerseError.microphonePermissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(
                url: temporaryURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 24_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
            )
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw PointVerseError.audioSessionUnavailable }
            self.recorder = recorder
        } catch let error as PointVerseError {
            throw error
        } catch {
            throw PointVerseError.audioSessionUnavailable
        }
    }

    func stop() async throws -> RecordingResult {
        guard let recorder else { throw PointVerseError.audioCommitFailed }
        let duration = max(0, Int(recorder.currentTime * 1_000))
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw PointVerseError.audioCommitFailed
        }
        return RecordingResult(temporaryURL: url, durationMilliseconds: duration)
    }

    func cancel() async {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        try? FileManager.default.removeItem(at: url)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
