import AVFAudio
import Foundation

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
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            isPlaying = player.play()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in isPlaying = false }
    }
}
