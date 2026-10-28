import Foundation

// These CLI-only declarations match the shared engine's public domain types.
public enum PointVerseError: Error { case audioDecodeFailed, invalidModelOutput }
public enum RecordingVoiceState: String { case calm, animated, subdued, tense, unknown }

@main enum RecordingWorker {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2,
                  let payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
                  let path = payload["audio_path"] as? String else { throw PointVerseError.audioDecodeFailed }
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let result = try RecordingCoreMLInference.run(audioURL: URL(fileURLWithPath: path), speakerRoot: root, emotionRoot: root)
            var body: [String: Any] = ["model": result.models, "voice_state": result.state.rawValue,
                                      "speaker_embedding": result.vector ?? [], "speaker_dimension": 192,
                                      "scores_relative": true]
            if let value = result.score { body["score"] = value }
            if let value = result.emotion { body["emotion_candidate"] = value }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: body))
        } catch {
            FileHandle.standardError.write(Data("recording_inference_failed\n".utf8))
            exit(1)
        }
    }
}
