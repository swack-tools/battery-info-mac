import Darwin
import Foundation
import Metal

let requestedSeconds = Int(CommandLine.arguments.dropFirst().first ?? "15") ?? 15
let seconds = max(1, requestedSeconds)
let deadline = Date().addingTimeInterval(TimeInterval(seconds))
let workers = DispatchGroup()

for seed in 0..<ProcessInfo.processInfo.activeProcessorCount {
    workers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        var value = Double(seed + 1)
        while Date() < deadline {
            for _ in 0..<100_000 {
                value = sin(value) * cos(value) + 1.000_001
            }
        }
        withExtendedLifetime(value) {}
        workers.leave()
    }
}

if let device = MTLCreateSystemDefaultDevice(),
   let queue = device.makeCommandQueue(),
   let library = try? device.makeLibrary(
    source: """
    kernel void burn(device float *values [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float x = values[id];
        for (uint i = 0; i < 1024; ++i) {
            x = sin(x) * cos(x) + 1.0001f;
        }
        values[id] = x;
    }
    """,
    options: nil
   ),
   let function = library.makeFunction(name: "burn"),
   let pipeline = try? device.makeComputePipelineState(function: function),
   let buffer = device.makeBuffer(length: 1_048_576 * MemoryLayout<Float>.stride) {
    let groupWidth = min(256, pipeline.maxTotalThreadsPerThreadgroup)
    while Date() < deadline {
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { break }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 1_048_576, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
    }
}

workers.wait()
