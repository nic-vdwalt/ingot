import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()!
let counterSet = device.counterSets!.first { $0.name == "timestamp" }!
let queue = device.makeCommandQueue()!
func makeCounters() throws -> MTLCounterSampleBuffer {
    let descriptor = MTLCounterSampleBufferDescriptor()
    descriptor.counterSet = counterSet
    descriptor.sampleCount = 4
    descriptor.storageMode = .shared
    return try device.makeCounterSampleBuffer(descriptor: descriptor)
}
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 640, height: 480, mipmapped: false)
textureDescriptor.usage = .renderTarget
let texture = device.makeTexture(descriptor: textureDescriptor)!
let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .depth32Float, width: 640, height: 480, mipmapped: false)
depthDescriptor.usage = .renderTarget
let depthTexture = device.makeTexture(descriptor: depthDescriptor)!
let library = try device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_main(uint index [[vertex_id]]) {
    float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return float4(positions[index], 0, 1);
}
vertex float4 clipped_main(uint index [[vertex_id]]) {
    return float4(4 + float(index), 4, 0, 1);
}
fragment float4 fragment_main() { return float4(1,0,0,1); }
fragment float4 discard_main() { discard_fragment(); return float4(0); }
""", options: nil)
func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertex)
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
let drawn = try pipeline("vertex_main", "fragment_main")
let clipped = try pipeline("clipped_main", "fragment_main")
let discarded = try pipeline("vertex_main", "discard_main")
let depthPipelineDescriptor = MTLRenderPipelineDescriptor()
depthPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
depthPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
let depthPipeline = try device.makeRenderPipelineState(descriptor: depthPipelineDescriptor)
let depthStateDescriptor = MTLDepthStencilDescriptor()
depthStateDescriptor.isDepthWriteEnabled = true
depthStateDescriptor.depthCompareFunction = .always
let depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor)!
func emit(_ record: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
}
try emit(["kind": "device", "device": device.name,
          "os": ProcessInfo.processInfo.operatingSystemVersionString,
          "stage_sampling": device.supportsCounterSampling(.atStageBoundary),
          "draw_sampling": device.supportsCounterSampling(.atDrawBoundary),
          "blit_sampling": device.supportsCounterSampling(.atBlitBoundary)])
var submission = 0
for fresh in [false, true] {
    let reused = try makeCounters()
    for repetition in 0..<4 {
        for name in ["draw", "clear", "clipped", "discard", "depth"] {
            let counters = fresh ? try makeCounters() : reused
            let command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            if name == "depth" {
                pass.depthAttachment.texture = depthTexture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 1
            } else {
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
            }
            let samples = pass.sampleBufferAttachments[0]!
            samples.sampleBuffer = counters
            samples.startOfVertexSampleIndex = 0
            samples.endOfVertexSampleIndex = 1
            samples.startOfFragmentSampleIndex = 2
            samples.endOfFragmentSampleIndex = 3
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            if name != "clear" {
                encoder.setRenderPipelineState(name == "depth" ? depthPipeline :
                    (name == "clipped" ? clipped : (name == "discard" ? discarded : drawn)))
                if name == "depth" { encoder.setDepthStencilState(depthState) }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            command.commit()
            submission += 1
            command.waitUntilCompleted()
            let data = try counters.resolveCounterRange(0..<4)!
            let ticks = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
            try emit(["kind": "sample", "case": name, "fresh": fresh,
                      "repetition": repetition, "submission": submission,
                      "draw_encoded": name != "clear", "ticks": ticks,
                      "status": command.status.rawValue,
                      "error": command.error.map { String(describing: $0) } ?? ""])
            precondition(command.status == .completed && command.error == nil)
            if name == "draw" {
                precondition(ticks[0] > 0 && ticks[3] >= ticks[0])
            }
        }
    }
}
