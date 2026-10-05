import Foundation
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
    @State private var isSongPickerPresented = false
    @State private var isVideoDropTargeted = false
    @FocusState private var isSongSearchFocused: Bool

    var body: some View {
        songPickerHost
        .photosPicker(isPresented: $isVideoPickerPresented, selection: $pickedItem, matching: .videos)
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
            guard let item else { return }
            Task {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                    playback.load(url: movie.url)
                } catch {
                    processor.errorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var songPickerHost: some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            macSongDrawerHost
        } else {
            responsiveContent
                .sheet(isPresented: $isSongPickerPresented) {
                    songSearchSheet
                }
        }
    }

    private var macSongDrawerHost: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                responsiveContent

                if isSongPickerPresented {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isSongPickerPresented = false }
                        .transition(.opacity)
                        .zIndex(1)

                    songSearchContent
                        .frame(
                            width: min(geometry.size.width, min(440, max(320, geometry.size.width * 0.42))),
                            height: geometry.size.height
                        )
                        .background(.regularMaterial)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20))
                        .shadow(color: .black.opacity(0.25), radius: 20, x: -8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .animation(.snappy(duration: 0.28), value: isSongPickerPresented)
        }
    }

    private var responsiveContent: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    preview
                        .frame(width: geometry.size.height, height: geometry.size.height)

                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            sourcePicker
                            settingsPanel
                            statusPanel
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        sourcePicker
                            .padding(.horizontal)
                        preview
                            .frame(width: geometry.size.width, height: geometry.size.width)
                        settingsPanel
                            .padding(.horizontal)
                        statusPanel
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var header: some View {
        Text("White Box Cartoonization")
            .font(.title2.bold())
    }

    private var sourcePicker: some View {
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
    }

    private var settingsPanel: some View {
        VStack(spacing: 16) {
            Picker("Resolution", selection: $processor.inputSize) {
                Text("256 × 256 · Fast").tag(256)
                Text("384 × 384 · Detailed").tag(384)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $processor.usesPersonSegmentation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Person on green screen")
                    Text("Apple Vision segmentation runs before cartoonization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Model input blur")
                    Spacer()
                    Text(processor.inputBlurRadius == 0
                         ? "Off"
                         : String(format: "%.1f px", processor.inputBlurRadius))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $processor.inputBlurRadius, in: 0...20, step: 0.5)
                    .accessibilityLabel("Model input blur radius")
                Text("Applied after resizing, immediately before Core ML")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            songControl
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var songControl: some View {
        if let track = songPreview.track {
            HStack(spacing: 10) {
                Button {
                    songPreview.togglePlayback()
                } label: {
                    Image(systemName: songPreview.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name).lineLimit(1)
                    Text("\(track.artist) · iTunes preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                if let storeURL = track.storeURL {
                    Link(destination: storeURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("View in iTunes")
                }
                Button {
                    isSongPickerPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Choose another song")
            }
        } else {
            Button {
                isSongPickerPresented = true
            } label: {
                Label("Choose a song", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if let image = processor.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                ContentUnavailableView("Waiting for a frame", systemImage: source == .camera ? "camera" : "film")
                    .foregroundStyle(.white)
            }

            VStack {
                Spacer()
                performanceOverlay
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }

            if isVideoDropTargeted {
                Color.black.opacity(0.45)
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 34))
                    Text("Drop video to cartoonize")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
        }
        .clipped()
        .overlay {
            if isVideoDropTargeted {
                Rectangle()
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
            }
        }
        .dropDestination(for: PickedMovie.self) { movies, _ in
            guard let movie = movies.first else { return false }
            source = .video
            pickedItem = nil
            playback.load(url: movie.url)
            return true
        } isTargeted: { isTargeted in
            isVideoDropTargeted = isTargeted
        }
    }

    private var performanceOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(String(format: "%.1f FPS", processor.throughputFPS))
                Text(String(format: "%.1f ms total", processor.pipelineLatencyMS))
            }
            Text(String(format: "%d² · %.1f ms Core ML", processor.inputSize, processor.modelLatencyMS))
            if processor.inputBlurRadius > 0 {
                Text(String(format: "Input blur · %.1f px", processor.inputBlurRadius))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusPanel: some View {
        VStack(spacing: 12) {
            if source == .video {
                if playback.hasVideo {
                    Button(playback.isPlaying ? "Pause" : "Play") {
                        playback.isPlaying ? playback.pause() : playback.play()
                    }
                } else {
                    Text("Tap Video to choose a clip, or drop one onto the preview.")
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
        .frame(maxWidth: 640)
    }

    private var songSearchSheet: some View {
        songSearchContent
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    private var songSearchContent: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Song or artist", text: $songPreview.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSongSearchFocused)
                        .onSubmit { songPreview.search() }
                    Button {
                        songPreview.search()
                    } label: {
                        if songPreview.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(songPreview.isSearching)
                }
                .padding(.horizontal)

                if songPreview.results.isEmpty {
                    if songPreview.isSearching {
                        Spacer()
                        ProgressView("Finding songs…")
                        Spacer()
                    } else if let error = songPreview.errorMessage {
                        ContentUnavailableView(
                            "Search failed",
                            systemImage: "exclamationmark.magnifyingglass",
                            description: Text(error)
                        )
                    } else {
                        ContentUnavailableView(
                            "Find a song",
                            systemImage: "music.note.list",
                            description: Text("Search iTunes and choose from up to 10 preview tracks.")
                        )
                    }
                } else {
                    List(songPreview.results) { result in
                        Button {
                            songPreview.selectTrack(id: result.id)
                            isSongPickerPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).lineLimit(1)
                                    Text(result.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if songPreview.selectedTrackID == result.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }

                Text("Preview provided courtesy of iTunes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top)
            .navigationTitle("Choose a Song")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isSongPickerPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .onAppear { isSongSearchFocused = true }
        }
    }

    private func select(_ input: InputSource) {
        source = input
        guard input == .video else { return }
        pickedItem = nil
        isVideoPickerPresented = true
    }

    private func wireInputs() {
        camera.onFrame = { [weak processor] buffer in
            DispatchQueue.main.async { processor?.submit(buffer) }
        }
        playback.onFrame = { [weak processor] buffer, transform in
            processor?.submit(buffer, sourceTransform: transform)
        }
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
