import Foundation
import Metal

public enum MetalError: Error, CustomStringConvertible {
    case noDevice
    case missingLibrary
    case missingFunction(String)
    case commandFailed(String)
    case badArgument(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .missingLibrary: "AutoGrade.metallib is not in the AutoGradeCore bundle (did the pre-build phase run?)"
        case .missingFunction(let name): "kernel \(name) is not in AutoGrade.metallib"
        case .commandFailed(let message): "Metal command failed: \(message)"
        case .badArgument(let message): "bad kernel argument: \(message)"
        }
    }
}

/// Device, queue and the project's one metallib. Pipelines are built on first
/// use and cached; the cache is the only mutable state, guarded by a lock.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MetalError.noDevice
        }
        // The kernels come from Tools/build-metallib.sh (safe math), never from
        // Xcode's default Metal build, which compiles fast math.
        guard let url = Bundle(for: MetalContext.self).url(forResource: "AutoGrade", withExtension: "metallib") else {
            throw MetalError.missingLibrary
        }
        self.device = device
        self.queue = queue
        self.library = try device.makeLibrary(URL: url)
    }

    public func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else { throw MetalError.missingFunction(name) }
        let state = try device.makeComputePipelineState(function: function)
        pipelines[name] = state
        return state
    }

    /// Encode with `body`, commit, and wait. Errors from the GPU are rethrown.
    public func run(_ body: (MTLComputeCommandEncoder) throws -> Void) throws {
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
            throw MetalError.commandFailed("could not create a command buffer")
        }
        do {
            try body(encoder)
        } catch {
            encoder.endEncoding()   // an encoder left open aborts the process; end it, then report
            throw error
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw MetalError.commandFailed(error.localizedDescription) }
    }
}
