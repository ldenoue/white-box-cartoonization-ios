import AVFoundation
import Foundation

@MainActor
final class VideoPlayback: ObservableObject {
    @Published var isPlaying = false
    @Published private(set) var hasVideo = false
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var preferredTransform = CGAffineTransform.identity
    var onFrame: ((CVPixelBuffer, CGAffineTransform) -> Void)?

    func load(url: URL) {
        stop()
        let asset = AVURLAsset(url: url)
        loadTask = Task { [weak self] in
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
                let transform = try await track.load(.preferredTransform)
                guard !Task.isCancelled else { return }
                self?.prepare(asset: asset, preferredTransform: transform)
            } catch {
                guard !Task.isCancelled else { return }
                self?.hasVideo = false
            }
        }
    }

    private func prepare(asset: AVAsset, preferredTransform: CGAffineTransform) {
        self.preferredTransform = preferredTransform
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        player = AVPlayer(playerItem: item)
        player?.isMuted = true
        player?.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartFromBeginning() }
        }
        hasVideo = true
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
        loadTask?.cancel()
        loadTask = nil
        pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player = nil
        videoOutput = nil
        preferredTransform = .identity
        hasVideo = false
    }

    private func restartFromBeginning() {
        guard let player else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    private func tick() {
        guard let player, let videoOutput else { return }
        let time = player.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        onFrame?(buffer, preferredTransform)
    }
}
