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
    @Published var inputSize = 256
    @Published var inputBlurRadius = 0.0

    private let worker = InferenceWorker()
    private var processing = false
    private var lastCompletion: ContinuousClock.Instant?

    func submit(_ pixelBuffer: CVPixelBuffer, sourceTransform: CGAffineTransform = .identity) {
        guard !processing else { return }
        processing = true
        worker.submit(
            pixelBuffer,
            sourceTransform: sourceTransform,
            inputSize: inputSize,
            inputBlurRadius: inputBlurRadius,
            applyingPersonSegmentation: usesPersonSegmentation
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

    private let queue = DispatchQueue(label: "WhiteBoxCartoonization.inference", qos: .userInitiated)
    private var cartoonizers: [Int: Cartoonizer] = [:]

    func submit(
        _ pixelBuffer: CVPixelBuffer,
        sourceTransform: CGAffineTransform,
        inputSize: Int,
        inputBlurRadius: Double,
        applyingPersonSegmentation: Bool,
        completion: @escaping @Sendable (Result<Cartoonizer.Result, Error>) -> Void
    ) {
        let box = PixelBufferBox(pixelBuffer)
        queue.async { [self, box] in
            do {
                let engine = try cartoonizers[inputSize] ?? Cartoonizer(inputSize: inputSize)
                cartoonizers[inputSize] = engine
                completion(.success(try engine.predict(
                    box.value,
                    sourceTransform: sourceTransform,
                    inputBlurRadius: inputBlurRadius,
                    applyingPersonSegmentation: applyingPersonSegmentation
                )))
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
