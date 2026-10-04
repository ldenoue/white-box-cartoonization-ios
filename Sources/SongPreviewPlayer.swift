import AVFoundation
import Foundation

struct SongPreviewTrack {
    let name: String
    let artist: String
    let previewURL: URL
    let storeURL: URL?
}

@MainActor
final class SongPreviewPlayer: ObservableObject {
    @Published var query = ""
    @Published private(set) var track: SongPreviewTrack?
    @Published private(set) var isSearching = false
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?

    func searchAndPlay() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            errorMessage = "Enter a song or artist."
            return
        }
        searchTask?.cancel()
        stopPlayer()
        track = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            isSearching = true
            errorMessage = nil
            defer { isSearching = false }
            do {
                let response = try await search(term: term)
                try Task.checkCancellation()
                guard let result = response.results.first else {
                    throw SearchError.noResults
                }
                guard let previewURL = result.previewUrl else {
                    throw SearchError.noPreview
                }
                play(SongPreviewTrack(
                    name: result.trackName,
                    artist: result.artistName,
                    previewURL: secureURL(previewURL),
                    storeURL: result.trackViewUrl.map(secureURL)
                ))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        stopPlayer()
        track = nil
    }

    private func stopPlayer() {
        player?.pause()
        player = nil
        isPlaying = false
        removeEndObserver()
    }

    private func search(term: String) async throws -> SearchResponse {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")
        ]
        guard let url = components.url else { throw SearchError.invalidRequest }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SearchError.requestFailed
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }

    private func play(_ track: SongPreviewTrack) {
        stopPlayer()
        self.track = track
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        #endif
        let item = AVPlayerItem(url: track.previewURL)
        player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnd() }
        }
        player?.play()
        isPlaying = true
    }

    private func secureURL(_ url: URL) -> URL {
        guard url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func handlePlaybackEnd() {
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaying = false
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

private struct SearchResponse: Decodable {
    let results: [SearchResult]
}

private struct SearchResult: Decodable {
    let artistName: String
    let trackName: String
    let previewUrl: URL?
    let trackViewUrl: URL?
}

private enum SearchError: LocalizedError {
    case invalidRequest
    case requestFailed
    case noResults
    case noPreview

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Could not create the search request."
        case .requestFailed: "The iTunes search request failed."
        case .noResults: "No songs matched that search."
        case .noPreview: "The first matching song has no preview."
        }
    }
}
