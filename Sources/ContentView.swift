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
    @State private var source = InputSource.camera
    @State private var pickedItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            Text("White Box Cartoonization")
                .font(.title2.bold())

            Picker("Input", selection: $source) {
                ForEach(InputSource.allCases) { Text($0.rawValue).tag($0) }
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
                Text(String(format: "Core ML %.1f ms", processor.modelLatencyMS))
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())

            if source == .video {
                HStack {
                    PhotosPicker(selection: $pickedItem, matching: .videos) {
                        Label("Choose Video", systemImage: "photo.on.rectangle")
                    }
                    Button(playback.isPlaying ? "Pause" : "Play") {
                        playback.isPlaying ? playback.pause() : playback.play()
                    }
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
        .onAppear {
            wireInputs()
            camera.start()
        }
        .onDisappear {
            camera.stop()
            playback.stop()
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
