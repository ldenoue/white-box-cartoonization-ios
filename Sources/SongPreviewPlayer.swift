import AVFoundation
import Foundation

struct SongPreviewTrack: Identifiable {
    let id: Int
    let name: String
    let artist: String
    let previewURL: URL
    let storeURL: URL?
}

@MainActor
final class SongPreviewPlayer: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [SongPreviewTrack] = []
    @Published private(set) var selectedTrackID: Int?
    @Published private(set) var track: SongPreviewTrack?
    @Published private(set) var isSearching = false
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            errorMessage = "Enter a song or artist."
            return
        }
        searchTask?.cancel()
        stopPlayer()
        results = []
        selectedTrackID = nil
        track = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            isSearching = true
            errorMessage = nil
            defer { isSearching = false }
            do {
                let response = try await search(term: term)
                try Task.checkCancellation()
                guard !response.results.isEmpty else {
                    throw SearchError.noResults
                }
                let previewableTracks = response.results.compactMap { result -> SongPreviewTrack? in
                    guard let previewURL = result.previewUrl else { return nil }
                    return SongPreviewTrack(
                        id: result.trackId,
                        name: result.trackName,
                        artist: result.artistName,
                        previewURL: self.secureURL(previewURL),
                        storeURL: result.trackViewUrl.map { self.secureURL($0) }
                    )
                }
                guard !previewableTracks.isEmpty else {
                    throw SearchError.noPreview
                }
                results = previewableTracks
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectTrack(id: Int?) {
        stopPlayer()
        selectedTrackID = id
        guard let id, let selectedTrack = results.first(where: { $0.id == id }) else {
            track = nil
            return
        }
        play(selectedTrack)
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
        results = []
        selectedTrackID = nil
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
            URLQueryItem(name: "limit", value: "10"),
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
        player?.actionAtItemEnd = .pause
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
        guard let player else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
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
    let trackId: Int
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
        case .noPreview: "None of the matching songs has a preview."
        }
    }
}
