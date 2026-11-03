import CoreML
import Foundation
import Metal

public enum GraderError: Error, CustomStringConvertible {
    case missingModel
    case badOutput(String)

    public var description: String {
        switch self {
        case .missingModel: "AdaIntFiveK.mlmodelc is not in the AutoGradeCore bundle"
        case .badOutput(let message): "unexpected model output: \(message)"
        }
    }
}

/// Whatever turns a 256x256 planar RGB image into a per-image AiLUT: the
/// CoreML network in the app, a fixed AiLUT in tests (StyleTests).
public protocol LUTPredictor: AnyObject, Sendable {
    func predict(_ resized: PlanarImage) throws -> AiLUT
}

/// The AdaInt network (Resources/Models/AdaIntFiveK.mlpackage, or an installed
/// style, CLAUDE.md 风格模型): a 256x256 planar RGB image in, the per-image
/// AiLUT out. Resizing and applying the LUT are Metal's job (GradeKernels), so
/// each step is held to its own fixture.
public final class Grader: LUTPredictor, @unchecked Sendable {
    public static let inputSide = 256
    public static let lutSize = 33
    public let model: MLModel
    private let kernels: GradeKernels

    /// The built-in FiveK model's compiled location inside the framework.
    public static func builtinModelURL() throws -> URL {
        guard let url = Bundle(for: Grader.self).url(forResource: "AdaIntFiveK", withExtension: "mlmodelc") else {
            throw GraderError.missingModel
        }
        return url
    }

    /// `.cpuAndGPU` with the fp32 model is the configuration the parity tests
    /// hold to 1e-4. The Neural Engine runs fp16 and is a separate measurement
    /// (CLAUDE.md, 精度与对照纪律).
    public convenience init(kernels: GradeKernels, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        try self.init(kernels: kernels, modelURL: try Self.builtinModelURL(), computeUnits: computeUnits)
    }

    /// `modelURL` is a compiled `.mlmodelc` with the AdaInt network's inputs and outputs.
    public init(kernels: GradeKernels, modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.kernels = kernels
        let inputs = model.modelDescription.inputDescriptionsByName, outputs = model.modelDescription.outputDescriptionsByName
        guard inputs["image"] != nil, outputs["lut"] != nil, outputs["vertices"] != nil else {
            throw GraderError.badOutput("\(modelURL.lastPathComponent) is not an AdaInt network (inputs \(inputs.keys.sorted()), outputs \(outputs.keys.sorted()))")
        }
    }

    /// `resized` must be 256x256 (GradeKernels.resize) and its producing command complete.
    public func predict(_ resized: PlanarImage) throws -> AiLUT {
        let side = Self.inputSide
        precondition(resized.width == side && resized.height == side)
        let input = try MLMultiArray(dataPointer: resized.buffer.contents(),
                                     shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32,
                                     strides: [NSNumber(value: 3 * side * side), NSNumber(value: side * side),
                                               NSNumber(value: side), 1])
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        let d = Self.lutSize
        let lut = try contiguousFloats(result, "lut", count: 3 * d * d * d)
        let vertices = try contiguousFloats(result, "vertices", count: 3 * d)
        return try kernels.makeAiLUT(lut: lut, vertices: vertices, size: d)
    }

    private func contiguousFloats(_ result: MLFeatureProvider, _ name: String, count: Int) throws -> [Float] {
        guard let array = result.featureValue(for: name)?.multiArrayValue else {
            throw GraderError.badOutput("no \(name)")
        }
        guard array.dataType == .float32, array.count == count else {
            throw GraderError.badOutput("\(name): \(array.dataType.rawValue) x \(array.count), want float32 x \(count)")
        }
        // CoreML pads the innermost axis (measured: the 33-wide LUT rows come back
        // with stride 48), so copy row by row through the strides into row-major order.
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard strides.last == 1 else { throw GraderError.badOutput("\(name): innermost stride \(strides)") }
        let rowLength = shape.last!, rows = count / rowLength
        let span = zip(shape, strides).map { ($0 - 1) * $1 }.reduce(0, +) + 1
        let base = array.dataPointer.bindMemory(to: Float.self, capacity: span)
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { dst in
            var index = [Int](repeating: 0, count: shape.count - 1)   // outer axes
            for row in 0..<rows {
                var offset = 0
                for axis in 0..<index.count { offset += index[axis] * strides[axis] }
                (dst.baseAddress! + row * rowLength).update(from: base + offset, count: rowLength)
                var axis = index.count - 1
                while axis >= 0 {
                    index[axis] += 1
                    if index[axis] < shape[axis] { break }
                    index[axis] = 0
                    axis -= 1
                }
            }
        }
        return out
    }
}
