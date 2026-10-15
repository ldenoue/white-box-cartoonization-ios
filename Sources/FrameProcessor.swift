import CoreGraphics
import CoreVideo
import Foundation

@MainActor
final class FrameProcessor: ObservableObject {
    @Published var image: CGImage?
    @Published var modelLatencyMS = 0.0
    @Published var pipelineLatencyMS = 0.0
    @Published var throughputFPS = 0.0
    @Published var errorMessage: String?
    @Published var usesPersonSegmentation = false
    @Published var inputSize = 256 {
        didSet {
            guard inputSize != oldValue, let backgroundPhotoData else { return }
            processBackgroundPhoto(backgroundPhotoData)
        }
    }
    @Published var inputBlurRadius = 0.0
    @Published private(set) var backgroundImage: CGImage?
    @Published private(set) var isBackgroundProcessing = false

    private let worker = InferenceWorker()
    private var processing = false
    private var lastCompletion: ContinuousClock.Instant?
    private var backgroundPhotoData: Data?
    private var backgroundRequestID = UUID()

    func submit(_ pixelBuffer: CVPixelBuffer, sourceTransform: CGAffineTransform = .identity) {
        guard !processing else { return }
        processing = true
        worker.submit(
            pixelBuffer,
            sourceTransform: sourceTransform,
            inputSize: inputSize,
            inputBlurRadius: inputBlurRadius,
            applyingPersonSegmentation: usesPersonSegmentation,
            backgroundImage: backgroundImage
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let output):
                    self.complete(output)
                case .failure(let error):
                    self.processing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setBackgroundPhoto(_ data: Data) {
        backgroundPhotoData = data
        processBackgroundPhoto(data)
    }

    func clearBackgroundPhoto() {
        backgroundRequestID = UUID()
        backgroundPhotoData = nil
        backgroundImage = nil
        isBackgroundProcessing = false
    }

    private func processBackgroundPhoto(_ data: Data) {
        let requestID = UUID()
        let requestedSize = inputSize
        backgroundRequestID = requestID
        backgroundImage = nil
        isBackgroundProcessing = true
        errorMessage = nil
        worker.submitBackgroundPhoto(data, inputSize: requestedSize) { [weak self] result in
            Task { @MainActor in
                guard let self,
                      self.backgroundRequestID == requestID,
                      self.inputSize == requestedSize,
                      self.backgroundPhotoData != nil else { return }
                self.isBackgroundProcessing = false
                switch result {
                case .success(let output):
                    self.backgroundImage = output.image
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func complete(_ result: Cartoonizer.Result) {
        let now = ContinuousClock.now
        if let lastCompletion {
            let interval = lastCompletion.duration(to: now).timeInterval
            throughputFPS = interval > 0 ? 1 / interval : 0
        }
        lastCompletion = now
        image = result.image
        modelLatencyMS = result.modelLatency * 1_000
        pipelineLatencyMS = result.pipelineLatency * 1_000
        processing = false
    }
}

private final class InferenceWorker: @unchecked Sendable {
    private final class PixelBufferBox: @unchecked Sendable {
        let value: CVPixelBuffer
        init(_ value: CVPixelBuffer) { self.value = value }
    }

    private final class CGImageBox: @unchecked Sendable {
        let value: CGImage?
        init(_ value: CGImage?) { self.value = value }
    }

    private let queue = DispatchQueue(label: "WhiteBoxCartoonization.inference", qos: .userInitiated)
    private var cartoonizers: [Int: Cartoonizer] = [:]

    func submit(
        _ pixelBuffer: CVPixelBuffer,
        sourceTransform: CGAffineTransform,
        inputSize: Int,
        inputBlurRadius: Double,
        applyingPersonSegmentation: Bool,
        backgroundImage: CGImage?,
        completion: @escaping @Sendable (Result<Cartoonizer.Result, Error>) -> Void
    ) {
        let box = PixelBufferBox(pixelBuffer)
        let backgroundBox = CGImageBox(backgroundImage)
        queue.async { [self, box, backgroundBox] in
            do {
                let engine = try cartoonizers[inputSize] ?? Cartoonizer(inputSize: inputSize)
                cartoonizers[inputSize] = engine
                completion(.success(try engine.predict(
                    box.value,
                    sourceTransform: sourceTransform,
                    inputBlurRadius: inputBlurRadius,
                    applyingPersonSegmentation: applyingPersonSegmentation,
                    backgroundImage: backgroundBox.value
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func submitBackgroundPhoto(
        _ data: Data,
        inputSize: Int,
        completion: @escaping @Sendable (Result<Cartoonizer.Result, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                let engine = try cartoonizers[inputSize] ?? Cartoonizer(inputSize: inputSize)
                cartoonizers[inputSize] = engine
                completion(.success(try engine.predict(photoData: data)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
