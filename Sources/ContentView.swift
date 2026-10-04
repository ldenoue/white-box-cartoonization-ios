import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum InputSource: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case video = "Video"
    var id: Self { self }
}

struct ContentView: View {
    @StateObject private var processor = FrameProcessor()
    @StateObject private var camera = CameraCapture()
    @StateObject private var playback = VideoPlayback()
    @StateObject private var songPreview = SongPreviewPlayer()
    @State private var source = InputSource.camera
    @State private var pickedItem: PhotosPickerItem?
    @State private var isVideoPickerPresented = false

    var body: some View {
        VStack(spacing: 16) {
            Text("White Box Cartoonization")
                .font(.title2.bold())

            HStack(spacing: 2) {
                ForEach(InputSource.allCases) { input in
                    Button(input.rawValue) {
                        select(input)
                    }
                    .buttonStyle(.plain)
                    .font(.body.weight(source == input ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(source == input ? 0.12 : 0), in: Capsule())
                    .accessibilityAddTraits(source == input ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .frame(maxWidth: 420)

            Picker("Resolution", selection: $processor.inputSize) {
                Text("256 × 256 · Fast").tag(256)
                Text("384 × 384 · Detailed").tag(384)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Toggle(isOn: $processor.usesPersonSegmentation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Person on green screen")
                    Text("Apple Vision segmentation runs before cartoonization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Song or artist", text: $songPreview.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { songPreview.searchAndPlay() }
                    Button {
                        songPreview.searchAndPlay()
                    } label: {
                        if songPreview.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Play first result", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(songPreview.isSearching)
                }
                if let track = songPreview.track {
                    HStack(spacing: 8) {
                        Button {
                            songPreview.togglePlayback()
                        } label: {
                            Image(systemName: songPreview.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.name).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let storeURL = track.storeURL {
                            Link("View in iTunes", destination: storeURL)
                                .font(.caption)
                        }
                    }
                    Text("Preview provided courtesy of iTunes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let error = songPreview.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 420)

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.black)
                if let image = processor.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Waiting for a frame", systemImage: source == .camera ? "camera" : "film")
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 640, maxHeight: 640)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 18) {
                Label(String(format: "%.1f ms pipeline", processor.pipelineLatencyMS), systemImage: "gauge.with.dots.needle.67percent")
                Label(String(format: "%.1f FPS", processor.throughputFPS), systemImage: "speedometer")
                Text(String(format: "%d² · Core ML %.1f ms", processor.inputSize, processor.modelLatencyMS))
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())

            if source == .video {
                if playback.hasVideo {
                    Button(playback.isPlaying ? "Pause" : "Play") {
                        playback.isPlaying ? playback.pause() : playback.play()
                    }
                } else {
                    Text("Tap Video to choose a clip.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Camera frames never leave this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = processor.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 560)
        #if os(macOS)
        .fileImporter(
            isPresented: $isVideoPickerPresented,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            importMacVideo(result)
        }
        #else
        .photosPicker(isPresented: $isVideoPickerPresented, selection: $pickedItem, matching: .videos)
        #endif
        .onAppear {
            wireInputs()
            camera.start()
        }
        .onDisappear {
            camera.stop()
            playback.stop()
            songPreview.stop()
        }
        .onChange(of: source) { _, newValue in
            if newValue == .camera {
                playback.pause()
                camera.start()
            } else {
                camera.stop()
            }
        }
        .onChange(of: pickedItem) { _, item in
            #if !os(macOS)
            guard let item else { return }
            Task {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                    playback.load(url: movie.url)
                } catch {
                    processor.errorMessage = error.localizedDescription
                }
            }
            #endif
        }
    }

    private func select(_ input: InputSource) {
        source = input
        guard input == .video else { return }
        pickedItem = nil
        isVideoPickerPresented = true
    }

    #if os(macOS)
    private func importMacVideo(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            playback.load(url: try Self.copyVideoToTemporaryDirectory(sourceURL))
        } catch {
            processor.errorMessage = error.localizedDescription
        }
    }
    #endif

    private static func copyVideoToTemporaryDirectory(_ sourceURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func wireInputs() {
        camera.onFrame = { [weak processor] buffer in
            DispatchQueue.main.async { processor?.submit(buffer) }
        }
        playback.onFrame = { [weak processor] buffer in processor?.submit(buffer) }
    }
}

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
