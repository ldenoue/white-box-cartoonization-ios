import AVFoundation
import Foundation

@MainActor
final class VideoPlayback: ObservableObject {
    @Published var isPlaying = false
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timer: Timer?
    var onFrame: ((CVPixelBuffer) -> Void)?

    func load(url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        player = AVPlayer(playerItem: item)
        player?.actionAtItemEnd = .pause
        play()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        player = nil
        videoOutput = nil
    }

    private func tick() {
        guard let player, let videoOutput else { return }
        let time = player.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        onFrame?(buffer)
    }
}
