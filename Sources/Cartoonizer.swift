import CoreImage
import CoreML
import Foundation
import Vision

final class Cartoonizer: @unchecked Sendable {
    struct Result: @unchecked Sendable {
        let image: CGImage
        let modelLatency: TimeInterval
        let pipelineLatency: TimeInterval
    }

    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let personSegmentationRequest: VNGeneratePersonSegmentationRequest
    private let inputSize: CGFloat
    private var inputBuffer: CVPixelBuffer

    init(inputSize: Int) throws {
        let modelName = "WhiteBoxCartoonization\(inputSize)"
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(modelName).mlmodelc is missing from the app bundle."])
        }
        self.inputSize = CGFloat(inputSize)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = true
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        personSegmentationRequest = VNGeneratePersonSegmentationRequest()
        personSegmentationRequest.qualityLevel = .fast
        personSegmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        inputBuffer = try Self.makePixelBuffer(size: inputSize)
    }

    func predict(_ source: CVPixelBuffer, applyingPersonSegmentation: Bool) throws -> Result {
        let pipelineStarted = ContinuousClock.now
        var sourceImage = CIImage(cvPixelBuffer: source)
        if applyingPersonSegmentation {
            sourceImage = try greenScreenedPerson(from: source, sourceImage: sourceImage)
        }
        let extent = sourceImage.extent
        let side = min(extent.width, extent.height)
        let crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
        let scale = inputSize / side
        let prepared = sourceImage.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(
            prepared,
            to: inputBuffer,
            bounds: CGRect(x: 0, y: 0, width: inputSize, height: inputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let modelStarted = ContinuousClock.now
        let provider = try MLDictionaryFeatureProvider(dictionary: ["source": MLFeatureValue(pixelBuffer: inputBuffer)])
        let prediction = try model.prediction(from: provider)
        let modelLatency = modelStarted.duration(to: .now).timeInterval
        guard let output = prediction.featureValue(for: "cartoon")?.imageBufferValue else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "The Core ML model did not return its cartoon image."])
        }
        let outputImage = CIImage(cvPixelBuffer: output)
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "Could not render the model output."])
        }
        return Result(
            image: cgImage,
            modelLatency: modelLatency,
            pipelineLatency: pipelineStarted.duration(to: .now).timeInterval
        )
    }

    private func greenScreenedPerson(from pixelBuffer: CVPixelBuffer, sourceImage: CIImage) throws -> CIImage {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([personSegmentationRequest])
        guard let maskBuffer = personSegmentationRequest.results?.first?.pixelBuffer else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "Apple Vision did not return a person mask."])
        }

        let extent = sourceImage.extent
        let rawMask = CIImage(cvPixelBuffer: maskBuffer)
        let mask = rawMask.transformed(by: CGAffineTransform(
            scaleX: extent.width / rawMask.extent.width,
            y: extent.height / rawMask.extent.height
        ))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        return sourceImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: green,
            kCIInputMaskImageKey: mask
        ])
    }

    private static func makePixelBuffer(size: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size,
            size,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return buffer
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
