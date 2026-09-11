import AVFAudio
import Foundation
import PointVerseKit

actor SystemAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?

    func start(at temporaryURL: URL) async throws {
        PointVerseLog.capture.info("Recording start requested")
        let allowed: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            PointVerseLog.capture.info("Microphone permission is granted")
            allowed = true
        case .denied:
            PointVerseLog.capture.error("Microphone permission is denied")
            allowed = false
        case .undetermined:
            PointVerseLog.capture.info("Requesting microphone permission")
            allowed = await AVAudioApplication.requestRecordPermission()
            PointVerseLog.capture.info("Microphone permission request completed: \(allowed, privacy: .public)")
        @unknown default:
            PointVerseLog.capture.error("Microphone permission has unknown state")
            allowed = false
        }
        guard allowed else { throw PointVerseError.microphonePermissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` is a playback-oriented mode and returns paramErr (-50)
            // with a record session on some physical devices. This combination
            // supports both capture and the original-audio player.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            PointVerseLog.capture.info("Audio session category configured")
            try session.setActive(true)
            PointVerseLog.capture.info("Audio session activated")
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
            PointVerseLog.capture.info("AVAudioRecorder started")
        } catch let error as PointVerseError {
            PointVerseLog.capture.error("Recording start failed with PointVerse code: \(error.rawValue, privacy: .public)")
            throw error
        } catch {
            let nsError = error as NSError
            PointVerseLog.capture.error("Recording start failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            throw PointVerseError.audioSessionUnavailable
        }
    }

    func stop() async throws -> RecordingResult {
        guard let recorder else { throw PointVerseError.audioCommitFailed }
        let duration = max(0, Int(recorder.currentTime * 1_000))
        let url = recorder.url
        recorder.stop()
        PointVerseLog.capture.info("AVAudioRecorder stopped: durationMs=\(duration, privacy: .public)")
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
        PointVerseLog.capture.info("Recording cancelled")
        self.recorder = nil
        try? FileManager.default.removeItem(at: url)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
