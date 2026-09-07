// Native Metal replay of one captured selected-window pass.
//
// Consumes the same bundle as replay/main.odin (export_replay_bundle.py) and
// re-encodes exactly the topology the pinned wgpu-hal Metal backend emits for
// it (vendor/wgpu-hal/src/metal/command.rs, pinned control tree):
//   render encoder with sampleBufferAttachments[0] = {startOfVertex: 0,
//   endOfFragment: 1, others DontSample}, drawing the captured draws into the
//   CAMetalLayer drawable, then a blit encoder that resolveCounters(0..<2)
//   into a resolve buffer and copies 16 bytes into a per-slot readback,
//   one commit, one presentDrawable on a separate command buffer.
//
// Modes (one hypothesis per run):
//   --gpu-resolve        experiment 2: read the GPU-resolved readback after
//                        the command buffer completes (what wgpu maps).
//   --completed-resolve  experiment 3: encode no resolve in the render command
//                        buffer, wait for it to complete, then resolve and
//                        copy in a second command buffer. Diagnostic control
//                        only; never a production path.
// Both modes always record the final CPU-resolved samples so the two evidence
// types can be compared without ever being equated.
//
// Shader-translation boundary: the MSL below is a hand translation of the
// captured WGSL (shader.wgsl in the bundle). Structural equivalence of the
// arithmetic, sampling and blend usage is asserted by review, not bit
// identity with naga's MSL; the bundle's shader_sha256 is recorded alongside
// this file's sha256 so the pairing is auditable.
import AppKit
import CryptoKit
import Foundation
import Metal
import QuartzCore

struct Attribute: Decodable { let format: Int; let offset: Int; let shader_location: Int }
struct Blend: Decodable { let operation: Int; let src_factor: Int; let dst_factor: Int }
struct Pipeline: Decodable {
    let format: Int; let vertex_stride: Int; let attributes: [Attribute]
    let topology: Int; let cull_mode: Int; let sample_count: Int
    let blend_enabled: Bool; let blend_color: Blend; let blend_alpha: Blend; let write_mask: Int
}
struct AtlasRef: Decodable { let atlas_id: Int; let filter: Int }
struct Draw: Decodable {
    let vertices: String; let indices: String; let index_count: Int
    let fragment_entry: String; let pipeline: Pipeline; let atlas: AtlasRef?; let scissor: [Int]
}
struct Attachment: Decodable {
    let width: Int; let height: Int; let format: Int; let load: Int; let store: Int
    let sample_count: Int; let color_clear_bits: [UInt64]
}
struct Atlas: Decodable { let file: String; let width: Int; let height: Int; let sha256: String }
struct Manifest: Decodable {
    let bundle_version: Int; let frame: Int; let attachment: Attachment
    let projection_bits: [UInt32]; let shader_sha256: String
    let atlases: [String: Atlas]; let draws: [Draw]
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write("usage: native_replay <bundle> <iterations> <out.jsonl> [--gpu-resolve|--completed-resolve]\n".data(using: .utf8)!)
    exit(2)
}
let bundle = URL(fileURLWithPath: arguments[1])
let iterations = Int(arguments[2])!
precondition(iterations > 0 && iterations <= 100_000)
let completedResolve = arguments.contains("--completed-resolve")
let output = FileHandle(forWritingAtPath: arguments[3]) ?? {
    FileManager.default.createFile(atPath: arguments[3], contents: nil)
    return FileHandle(forWritingAtPath: arguments[3])!
}()
output.truncateFile(atOffset: 0)
func emit(_ record: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    output.write(bytes)
    output.write("\n".data(using: .utf8)!)
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
precondition(manifest.bundle_version == 1)
precondition(manifest.attachment.format == 27, "captured attachment is BGRA8Unorm")
precondition(manifest.attachment.sample_count == 1)
let shaderSource = try Data(contentsOf: bundle.appendingPathComponent("shader.wgsl"))
precondition(sha256(shaderSource) == manifest.shader_sha256, "bundle shader identity")

let device = MTLCreateSystemDefaultDevice()!
let counterSet = device.counterSets!.first { $0.name == "timestamp" }!
let queue = device.makeCommandQueue()!
let sampleDescriptor = MTLCounterSampleBufferDescriptor()
sampleDescriptor.counterSet = counterSet
sampleDescriptor.sampleCount = 128
sampleDescriptor.storageMode = .shared
let sampleBuffer = try device.makeCounterSampleBuffer(descriptor: sampleDescriptor)
let resolveBuffer = device.makeBuffer(length: 128 * 8, options: .storageModePrivate)!
let slotCount = 8
let readbacks = (0..<slotCount).map { _ in device.makeBuffer(length: 128 * 8, options: .storageModeShared)! }

// Hand translation of the captured WGSL. Uniform p: xy = 1/size, z = y flip.
let library = try device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
struct Uniforms { float4 p; };
struct VSIn {
    float2 pos [[attribute(0)]];
    float4 col [[attribute(1)]];
    float2 uv [[attribute(2)]];
    uint mode [[attribute(3)]];
};
struct VSOut {
    float4 pos [[position]];
    float4 col;
    float2 uv;
    uint mode [[flat]];
};
vertex VSOut vs_main(VSIn in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    VSOut o;
    float sx = in.pos.x * u.p.x * 2.0 - 1.0;
    float sy = 1.0 - in.pos.y * u.p.y * 2.0;
    o.pos = float4(sx, sy * u.p.z, 0.0, 1.0);
    o.col = in.col;
    o.uv = in.uv;
    o.mode = in.mode;
    return o;
}
fragment float4 fs_ui(VSOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler samp [[sampler(0)]]) {
    float sampled_alpha = atlas.sample(samp, in.uv).r;
    if (in.mode == 0u) {
        return float4(in.col.rgb * in.col.a, in.col.a);
    }
    float a = sampled_alpha * in.col.a;
    return float4(in.col.rgb * a, a);
}
fragment float4 fs_image(VSOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler samp [[sampler(0)]]) {
    float4 t = atlas.sample(samp, in.uv);
    float a = t.a * in.col.a;
    return float4(t.rgb * in.col.rgb * a, a);
}
""", options: nil)

func blendFactor(_ value: Int) -> MTLBlendFactor {
    // Pinned wgpu BlendFactor values: Zero=1 One=2 Src=3 OneMinusSrc=4 SrcAlpha=5 OneMinusSrcAlpha=6 Dst=7 OneMinusDst=8.
    switch value {
    case 1: return .zero
    case 2: return .one
    case 3: return .sourceColor
    case 4: return .oneMinusSourceColor
    case 5: return .sourceAlpha
    case 6: return .oneMinusSourceAlpha
    case 7: return .destinationColor
    case 8: return .oneMinusDestinationColor
    default: fatalError("unsupported blend factor \(value)")
    }
}
func blendOperation(_ value: Int) -> MTLBlendOperation {
    switch value {
    case 0: return .add
    case 1: return .subtract
    default: fatalError("unsupported blend operation \(value)")
    }
}
func vertexFormat(_ value: Int) -> MTLVertexFormat {
    switch value {
    case 0x1D: return .float2
    case 0x1F: return .float4
    case 0x20: return .uint
    default: fatalError("unsupported vertex format \(value)")
    }
}
func makePipeline(_ draw: Draw) throws -> MTLRenderPipelineState {
    precondition(draw.pipeline.topology == 4 && draw.pipeline.cull_mode == 1 && draw.pipeline.sample_count == 1)
    precondition(draw.pipeline.write_mask == 0xF)
    let vertexDescriptor = MTLVertexDescriptor()
    for attribute in draw.pipeline.attributes {
        vertexDescriptor.attributes[attribute.shader_location].format = vertexFormat(attribute.format)
        vertexDescriptor.attributes[attribute.shader_location].offset = attribute.offset
        vertexDescriptor.attributes[attribute.shader_location].bufferIndex = 0
    }
    vertexDescriptor.layouts[0].stride = draw.pipeline.vertex_stride
    vertexDescriptor.layouts[0].stepFunction = .perVertex
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "vs_main")
    descriptor.fragmentFunction = library.makeFunction(name: draw.fragment_entry)
    descriptor.vertexDescriptor = vertexDescriptor
    let target = descriptor.colorAttachments[0]!
    target.pixelFormat = .bgra8Unorm
    target.isBlendingEnabled = draw.pipeline.blend_enabled
    target.rgbBlendOperation = blendOperation(draw.pipeline.blend_color.operation)
    target.sourceRGBBlendFactor = blendFactor(draw.pipeline.blend_color.src_factor)
    target.destinationRGBBlendFactor = blendFactor(draw.pipeline.blend_color.dst_factor)
    target.alphaBlendOperation = blendOperation(draw.pipeline.blend_alpha.operation)
    target.sourceAlphaBlendFactor = blendFactor(draw.pipeline.blend_alpha.src_factor)
    target.destinationAlphaBlendFactor = blendFactor(draw.pipeline.blend_alpha.dst_factor)
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
func makeTexture(width: Int, height: Int, format: MTLPixelFormat, bytes: Data, bytesPerRow: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    let texture = device.makeTexture(descriptor: descriptor)!
    bytes.withUnsafeBytes { raw in
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
    }
    return texture
}
func makeSampler(linear: Bool) -> MTLSamplerState {
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = linear ? .linear : .nearest
    descriptor.magFilter = linear ? .linear : .nearest
    descriptor.mipFilter = .nearest
    descriptor.sAddressMode = .clampToEdge
    descriptor.tAddressMode = .clampToEdge
    descriptor.rAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: descriptor)!
}

let neutral = makeTexture(width: 1, height: 1, format: .rgba8Unorm, bytes: Data([255, 255, 255, 255]), bytesPerRow: 4)
let nearestSampler = makeSampler(linear: false)
let linearSampler = makeSampler(linear: true)
var atlases: [Int: MTLTexture] = [:]
for (key, atlas) in manifest.atlases {
    let pixels = try Data(contentsOf: bundle.appendingPathComponent(atlas.file))
    precondition(sha256(pixels) == atlas.sha256 && pixels.count == atlas.width * atlas.height)
    atlases[Int(key)!] = makeTexture(width: atlas.width, height: atlas.height, format: .r8Unorm, bytes: pixels, bytesPerRow: atlas.width)
}
struct PreparedDraw {
    let pipeline: MTLRenderPipelineState
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    let texture: MTLTexture
    let sampler: MTLSamplerState
    let scissor: MTLScissorRect
}
let draws: [PreparedDraw] = try manifest.draws.map { draw in
    let vertexData = try Data(contentsOf: bundle.appendingPathComponent(draw.vertices))
    let indexData = try Data(contentsOf: bundle.appendingPathComponent(draw.indices))
    precondition(indexData.count == draw.index_count * 4)
    let vertices = device.makeBuffer(bytes: [UInt8](vertexData), length: vertexData.count, options: .storageModeShared)!
    let indices = device.makeBuffer(bytes: [UInt8](indexData), length: indexData.count, options: .storageModeShared)!
    let texture = draw.atlas.map { atlases[$0.atlas_id]! } ?? neutral
    let sampler = (draw.atlas?.filter ?? 0) == 0 ? nearestSampler : linearSampler
    let scissor = MTLScissorRect(x: draw.scissor[0], y: draw.scissor[1], width: draw.scissor[2], height: draw.scissor[3])
    return PreparedDraw(pipeline: try makePipeline(draw), vertices: vertices, indices: indices,
                        indexCount: draw.index_count, texture: texture, sampler: sampler, scissor: scissor)
}
var projection = manifest.projection_bits
let uniforms = device.makeBuffer(bytes: &projection, length: 16, options: .storageModeShared)!
let clear = manifest.attachment.color_clear_bits.map { Double(bitPattern: $0) }

// Window and layer sized so the drawable matches the captured attachment.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let scale = NSScreen.main!.backingScaleFactor
let contentSize = NSSize(width: CGFloat(manifest.attachment.width) / scale, height: CGFloat(manifest.attachment.height) / scale)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "native timing replay"
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.framebufferOnly = true
layer.contentsScale = scale
layer.drawableSize = CGSize(width: manifest.attachment.width, height: manifest.attachment.height)
layer.displaySyncEnabled = true
window.contentView!.wantsLayer = true
window.contentView!.layer = layer
window.makeKeyAndOrderFront(nil)
app.finishLaunching()

let sourceData = try Data(contentsOf: URL(fileURLWithPath: #filePath))
emit(["kind": "header", "bundle": arguments[1], "frame": manifest.frame, "iterations": iterations,
      "mode": completedResolve ? "completed_resolve" : "gpu_resolve",
      "device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "source_sha256": sha256(sourceData), "shader_sha256": manifest.shader_sha256,
      "drawable_width": Int(layer.drawableSize.width), "drawable_height": Int(layer.drawableSize.height),
      "stage_sampling": device.supportsCounterSampling(.atStageBoundary),
      "draws": draws.count, "slots": slotCount])
precondition(Int(layer.drawableSize.width) == manifest.attachment.width && Int(layer.drawableSize.height) == manifest.attachment.height)

func classify(begin: UInt64, end: UInt64, prior: (UInt64, UInt64)) -> String {
    if end == 0 { return "zero_end" }
    if end < begin { return (end == prior.1 || end == prior.0) ? "reversed_prior_slot_value" : "reversed_nonzero" }
    if end == prior.1 { return "ordered_but_stale" }
    return "ordered"
}
var priors = Array(repeating: (UInt64(0), UInt64(0)), count: slotCount)
var priorKinds = Array(repeating: "", count: slotCount)
var pendingCommands: [(Int, Int, MTLCommandBuffer)] = []
func pump() {
    while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}
func collect(final: Bool) {
    var remaining: [(Int, Int, MTLCommandBuffer)] = []
    for (iteration, slot, command) in pendingCommands {
        if command.status != .completed && command.status != .error {
            if final { command.waitUntilCompleted() } else { remaining.append((iteration, slot, command)); continue }
        }
        // The GPU-resolved bytes are what wgpu maps; the CPU resolution after
        // completion is the separate evidence type for the same samples.
        let words = readbacks[slot].contents().bindMemory(to: UInt64.self, capacity: 2)
        let gpu = (words[0], words[1])
        var cpu: [UInt64] = []
        if let resolved = try? sampleBuffer.resolveCounterRange(0..<2) {
            cpu = resolved.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
        }
        var record: [String: Any] = [
            "kind": "sample", "iteration": iteration, "slot": slot,
            "status": command.status.rawValue, "error": command.error.map { "\($0)" } ?? "",
            "gpu_begin": gpu.0, "gpu_end": gpu.1,
            "prior_begin": priors[slot].0, "prior_end": priors[slot].1, "prior_kind": priorKinds[slot],
            "class": command.status == .completed ? classify(begin: gpu.0, end: gpu.1, prior: priors[slot]) : "failed_command",
            "cpu_samples": cpu, "final_drain": final,
        ]
        if cpu.count == 2 {
            record["cpu_class"] = classify(begin: cpu[0], end: cpu[1], prior: (0, 0))
            record["gpu_matches_cpu"] = cpu[0] == gpu.0 && cpu[1] == gpu.1
        }
        emit(record)
        priors[slot] = gpu
        priorKinds[slot] = "mapped"
    }
    pendingCommands = remaining
}
var submits = 0
var failures = 0
for iteration in 0..<iterations {
    autoreleasepool {
        pump()
        collect(final: false)
        let used = Set(pendingCommands.map { $0.1 })
        guard let slot = (0..<slotCount).first(where: { !used.contains($0) }) else {
            emit(["kind": "no_free_slot", "iteration": iteration])
            pendingCommands.first?.2.waitUntilCompleted()
            return
        }
        guard let drawable = layer.nextDrawable() else {
            emit(["kind": "acquire", "iteration": iteration, "status": -1])
            return
        }
        let command = queue.makeCommandBuffer()!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = manifest.attachment.load == 2 ? .clear : .load
        pass.colorAttachments[0].storeAction = manifest.attachment.store == 1 ? .store : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: clear[0], green: clear[1], blue: clear[2], alpha: clear[3])
        let sba = pass.sampleBufferAttachments[0]!
        sba.sampleBuffer = sampleBuffer
        sba.startOfVertexSampleIndex = 0
        sba.endOfVertexSampleIndex = MTLCounterDontSample
        sba.startOfFragmentSampleIndex = MTLCounterDontSample
        sba.endOfFragmentSampleIndex = 1
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        for draw in draws {
            encoder.setScissorRect(draw.scissor)
            encoder.setRenderPipelineState(draw.pipeline)
            encoder.setVertexBuffer(draw.vertices, offset: 0, index: 0)
            encoder.setVertexBuffer(uniforms, offset: 0, index: 1)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.setFragmentSamplerState(draw.sampler, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: draw.indexCount, indexType: .uint32, indexBuffer: draw.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        if !completedResolve {
            let blit = command.makeBlitCommandEncoder()!
            blit.resolveCounters(sampleBuffer, range: 0..<2, destinationBuffer: resolveBuffer, destinationOffset: 0)
            blit.copy(from: resolveBuffer, sourceOffset: 0, to: readbacks[slot], destinationOffset: 0, size: 16)
            blit.endEncoding()
        }
        command.commit()
        submits += 1
        // wgpu presents on its own command buffer after the submit (metal/mod.rs present()).
        let present = queue.makeCommandBuffer()!
        present.present(drawable)
        present.commit()
        if completedResolve {
            // Experiment 3 control: the render must be complete before the
            // counters are resolved, in their own command buffer.
            command.waitUntilCompleted()
            if command.status == .error { failures += 1 }
            let resolve = queue.makeCommandBuffer()!
            let blit = resolve.makeBlitCommandEncoder()!
            blit.resolveCounters(sampleBuffer, range: 0..<2, destinationBuffer: resolveBuffer, destinationOffset: 0)
            blit.copy(from: resolveBuffer, sourceOffset: 0, to: readbacks[slot], destinationOffset: 0, size: 16)
            blit.endEncoding()
            resolve.commit()
            pendingCommands.append((iteration, slot, resolve))
        } else {
            pendingCommands.append((iteration, slot, command))
        }
    }
}
collect(final: true)
emit(["kind": "footer", "submits": submits, "command_failures": failures, "drained": pendingCommands.isEmpty])
output.closeFile()
