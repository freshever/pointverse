import AVFAudio
import Foundation
import PointVerseKit

actor SystemAudioRecorder: AudioRecording {
    private static let voiceThreshold: Float = -45
    private static let minimumDurationMilliseconds = 1_000
    private var recorder: AVAudioRecorder?
    private var detectedVoice = false
    private var lastVoiceTime: TimeInterval?

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
            if ProcessInfo.processInfo.isiOSAppOnMac {
                // The iOS compatibility runtime on macOS rejects some speaker and
                // Bluetooth route options that are valid on an iPhone.
                try session.setCategory(.record, mode: .default, options: [])
            } else {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    // Xcode 16.2 names the hands-free Bluetooth recording option
                    // `.allowBluetooth`; newer SDKs expose `.allowBluetoothHFP`.
                    options: [.allowBluetooth, .defaultToSpeaker]
                )
            }
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
            detectedVoice = false
            lastVoiceTime = nil
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

    func activity() async -> AudioRecordingActivity {
        guard let recorder else {
            return AudioRecordingActivity(durationMilliseconds: 0, hasDetectedVoice: false, silenceMilliseconds: 0)
        }
        recorder.updateMeters()
        let currentTime = recorder.currentTime
        if recorder.averagePower(forChannel: 0) >= Self.voiceThreshold {
            detectedVoice = true
            lastVoiceTime = currentTime
        }
        let silence = lastVoiceTime.map { max(0, Int((currentTime - $0) * 1_000)) } ?? 0
        return AudioRecordingActivity(
            durationMilliseconds: Int(currentTime * 1_000),
            hasDetectedVoice: detectedVoice,
            silenceMilliseconds: silence
        )
    }

    func stop() async throws -> RecordingResult {
        guard let recorder else { throw PointVerseError.audioCommitFailed }
        let duration = max(0, Int(recorder.currentTime * 1_000))
        let url = recorder.url
        recorder.stop()
        PointVerseLog.capture.info("AVAudioRecorder stopped: durationMs=\(duration, privacy: .public)")
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard duration >= Self.minimumDurationMilliseconds, detectedVoice else {
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
