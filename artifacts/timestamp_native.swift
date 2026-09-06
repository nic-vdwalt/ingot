import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()!
let counterSet = device.counterSets!.first { $0.name == "timestamp" }!
let counterDescriptor = MTLCounterSampleBufferDescriptor()
counterDescriptor.counterSet = counterSet
counterDescriptor.sampleCount = 4
counterDescriptor.storageMode = .shared
let counters = try device.makeCounterSampleBuffer(descriptor: counterDescriptor)
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 480, mipmapped: false)
textureDescriptor.usage = .renderTarget
let texture = device.makeTexture(descriptor: textureDescriptor)!
let queue = device.makeCommandQueue()!
let library = try device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_main(uint index [[vertex_id]]) {
    float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return float4(positions[index], 0, 1);
}
fragment float4 fragment_main() { return float4(1,0,0,1); }
""", options: nil)
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
print("device=\(device.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
for frame in 0..<10 {
    let command = queue.makeCommandBuffer()!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let samples = pass.sampleBufferAttachments[0]!
    samples.sampleBuffer = counters
    samples.startOfVertexSampleIndex = 0
    samples.endOfVertexSampleIndex = 1
    samples.startOfFragmentSampleIndex = 2
    samples.endOfFragmentSampleIndex = 3
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    if frame % 2 == 0 {
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    let data = try counters.resolveCounterRange(0..<4)!
    let ticks = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
    print("frame=\(frame) ticks=\(ticks) error=\(String(describing: command.error))")
}
