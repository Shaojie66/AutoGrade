import AutoGradeCore
import Metal
import XCTest

/// Fails if the kernels were compiled with fast math (see Probe.metal).
final class ProbeTests: XCTestCase {
    func testKernelsAreCompiledWithPreciseMath() throws {
        let metal = try MetalContext()
        let n = 4096
        let xs = (0..<n).map { Float(-10.0 + 20.0 * Double($0) / Double(n - 1)) }
        let input = try XCTUnwrap(metal.device.makeBuffer(bytes: xs, length: n * 4, options: .storageModeShared))
        let output = try XCTUnwrap(metal.device.makeBuffer(length: n * 4, options: .storageModeShared))
        let pipeline = try metal.pipeline("probe_exp")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(input, offset: 0, index: 0)
            enc.setBuffer(output, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        let ys = output.contents().bindMemory(to: Float.self, capacity: n)
        var worstUlp: Float = 0
        for i in 0..<n {
            let exact = Float(Foundation.exp(Double(xs[i])))   // correctly rounded reference
            worstUlp = max(worstUlp, abs(ys[i] - exact) / exact.ulp)
        }
        print("probe_exp worst error: \(worstUlp) ulp (fast math measured 7 on M4 Max)")
        XCTAssertLessThanOrEqual(worstUlp, 4, "exp is \(worstUlp) ulp off: kernels built with fast math?")
    }
}
