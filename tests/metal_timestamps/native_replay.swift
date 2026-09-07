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
import Darwin
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
    FileHandle.standardError.write("usage: native_replay <bundle> <iterations> <out.jsonl> [--gpu-resolve|--completed-resolve|--publication-latency|--unique-indices|--all-stages|--gap N|--tracked-dependency|--blit-boundary-samples|--deferred-resolve enqueued|scheduled|completed]\n".data(using: .utf8)!)
    exit(2)
}
let bundle = URL(fileURLWithPath: arguments[1])
let iterations = Int(arguments[2])!
precondition(iterations > 0 && iterations <= 100_000)
let completedResolve = arguments.contains("--completed-resolve")
let publicationLatency = arguments.contains("--publication-latency")
let uniqueIndices = arguments.contains("--unique-indices")
let allStages = arguments.contains("--all-stages")
let trackedDependency = arguments.contains("--tracked-dependency")
let blitBoundarySamples = arguments.contains("--blit-boundary-samples")
let gapArgument = arguments.firstIndex(of: "--gap")
let gapDispatches = gapArgument.map { Int(arguments[$0 + 1])! } ?? 0
let deferredResolve = arguments.firstIndex(of: "--deferred-resolve").map { arguments[$0 + 1] }
if let deferredResolve { precondition(["enqueued", "scheduled", "completed"].contains(deferredResolve)) }
let experiment: String = {
    if publicationLatency { return "publication_latency" }
    if uniqueIndices { return "unique_indices" }
    if allStages { return "all_stages" }
    if trackedDependency { return "tracked_dependency" }
    if blitBoundarySamples { return "blit_boundary_samples" }
    if gapArgument != nil { return "gap_\(gapDispatches)" }
    if let deferredResolve { return "deferred_\(deferredResolve)" }
    return completedResolve ? "completed_resolve" : "gpu_resolve"
}()
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
let blitBoundarySupported = device.supportsCounterSampling(.atBlitBoundary)
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
kernel void gap_kernel(device uint *values [[buffer(0)]], uint index [[thread_position_in_grid]]) {
    values[index] = values[index] &+ index;
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
let gapBuffer = device.makeBuffer(length: 64 * 1024 * 1024, options: .storageModePrivate)!
let gapPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "gap_kernel")!)
let dependencyBuffer = device.makeBuffer(length: 256, options: .storageModePrivate)!
let boundaryBuffer = device.makeBuffer(length: 256, options: .storageModePrivate)!

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
let sourceSHA = sha256(sourceData)
let executableSHA = sha256(try Data(contentsOf: URL(fileURLWithPath: arguments[0])))
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func hostNanoseconds(_ ticks: UInt64) -> UInt64 {
    UInt64((UInt128(ticks) * UInt128(timebase.numer)) / UInt128(timebase.denom))
}
let clockStart = device.sampleTimestamps()
emit(["kind": "header", "bundle": arguments[1], "frame": manifest.frame, "iterations": iterations,
      "mode": completedResolve ? "completed_resolve" : "gpu_resolve", "experiment": experiment,
      "flags": Array(arguments.dropFirst(4)), "gap_dispatches": gapDispatches,
      "deferred_resolve": deferredResolve ?? "", "device": device.name,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "source_sha256": sourceSHA, "executable_sha256": executableSHA,
      "shader_sha256": manifest.shader_sha256,
      "clock_start_cpu": clockStart.cpu, "clock_start_cpu_ns": clockStart.cpu,
      "clock_start_gpu": clockStart.gpu,
      "drawable_width": Int(layer.drawableSize.width), "drawable_height": Int(layer.drawableSize.height),
      "stage_sampling": device.supportsCounterSampling(.atStageBoundary),
      "blit_boundary_sampling": blitBoundarySupported,
      "draws": draws.count, "slots": slotCount])
precondition(Int(layer.drawableSize.width) == manifest.attachment.width && Int(layer.drawableSize.height) == manifest.attachment.height)
if blitBoundarySamples && !blitBoundarySupported {
    emit(["kind": "unsupported", "experiment": experiment, "reason": "at_blit_boundary_unsupported"])
    emit(["kind": "footer", "experiment": experiment, "submits": 0,
          "command_failures": 0, "drained": true, "source_sha256": sourceSHA,
          "executable_sha256": executableSHA])
    output.closeFile()
    exit(0)
}

func classify(begin: UInt64, end: UInt64, prior: (UInt64, UInt64)) -> String {
    if end == 0 { return "zero_end" }
    if end < begin { return (end == prior.1 || end == prior.0) ? "reversed_prior_slot_value" : "reversed_nonzero" }
    if end == prior.1 { return "ordered_but_stale" }
    return "ordered"
}
func encodeRender(_ command: MTLCommandBuffer, _ drawable: CAMetalDrawable, _ indices: [Int]) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = manifest.attachment.load == 2 ? .clear : .load
    pass.colorAttachments[0].storeAction = manifest.attachment.store == 1 ? .store : .dontCare
    pass.colorAttachments[0].clearColor = MTLClearColor(red: clear[0], green: clear[1], blue: clear[2], alpha: clear[3])
    if !blitBoundarySamples {
        let samples = pass.sampleBufferAttachments[0]!
        samples.sampleBuffer = sampleBuffer
        samples.startOfVertexSampleIndex = indices[0]
        samples.endOfVertexSampleIndex = indices.count == 4 ? indices[1] : MTLCounterDontSample
        samples.startOfFragmentSampleIndex = indices.count == 4 ? indices[2] : MTLCounterDontSample
        samples.endOfFragmentSampleIndex = indices.last!
    }
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    encoder.label = "mechanism.render"
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
}
func encodeGap(_ command: MTLCommandBuffer) {
    guard gapDispatches > 0 else { return }
    let pass = MTLComputePassDescriptor()
    let samples = pass.sampleBufferAttachments[0]!
    samples.sampleBuffer = sampleBuffer
    samples.startOfEncoderSampleIndex = 4
    samples.endOfEncoderSampleIndex = 5
    let encoder = command.makeComputeCommandEncoder(descriptor: pass)!
    encoder.label = "mechanism.gap.\(gapDispatches)"
    encoder.setComputePipelineState(gapPipeline)
    encoder.setBuffer(gapBuffer, offset: 0, index: 0)
    for _ in 0..<gapDispatches {
        encoder.dispatchThreads(MTLSize(width: gapBuffer.length / 4, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: gapPipeline.threadExecutionWidth, height: 1, depth: 1))
    }
    encoder.endEncoding()
}
func encodeResolve(_ command: MTLCommandBuffer, _ drawable: CAMetalDrawable, _ indices: [Int], _ readback: MTLBuffer) {
    let blit = command.makeBlitCommandEncoder()!
    blit.label = "mechanism.resolve"
    if trackedDependency {
        blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: dependencyBuffer, destinationOffset: 0,
                  destinationBytesPerRow: 256, destinationBytesPerImage: 256)
    }
    let first = indices.min()!
    let last = gapDispatches > 0 ? 6 : indices.max()! + 1
    blit.resolveCounters(sampleBuffer, range: first..<last, destinationBuffer: resolveBuffer, destinationOffset: first * 8)
    blit.copy(from: resolveBuffer, sourceOffset: first * 8, to: readback, destinationOffset: first * 8, size: (last - first) * 8)
    blit.endEncoding()
}
func encodeBoundarySample(_ command: MTLCommandBuffer, _ index: Int) {
    let blit = command.makeBlitCommandEncoder()!
    blit.label = "mechanism.boundary.\(index)"
    blit.sampleCounters(sampleBuffer: sampleBuffer, sampleIndex: index, barrier: true)
    blit.fill(buffer: boundaryBuffer, range: 0..<1, value: 255)
    blit.endEncoding()
}
func pump() {
    while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}

var submits = 0
var failures = 0
var priorByIndex = Array(repeating: UInt64(0), count: 128)
var priorCPUByIndex = Array(repeating: UInt64(0), count: 128)
for iteration in 0..<iterations {
    autoreleasepool {
        pump()
        guard let drawable = layer.nextDrawable() else {
            emit(["kind": "acquire", "iteration": iteration, "status": -1, "experiment": experiment])
            return
        }
        let indices = uniqueIndices ? [iteration * 2 % 128, (iteration * 2 + 1) % 128] : (allStages ? [0, 1, 2, 3] : [0, 1])
        let readback = readbacks[iteration % slotCount]
        let command = queue.makeCommandBuffer()!
        command.label = "mechanism.render.\(iteration)"
        if blitBoundarySamples { encodeBoundarySample(command, indices[0]) }
        encodeRender(command, drawable, indices)
        encodeGap(command)
        if blitBoundarySamples { encodeBoundarySample(command, indices.last!) }
        let usesDeferred = deferredResolve != nil || completedResolve
        if !usesDeferred { encodeResolve(command, drawable, indices, readback) }

        let timingLock = NSLock()
        var scheduledHostNS: UInt64 = 0
        var completedHostNS: UInt64 = 0
        command.addScheduledHandler { _ in
            timingLock.lock(); scheduledHostNS = hostNanoseconds(mach_absolute_time()); timingLock.unlock()
        }
        command.addCompletedHandler { _ in
            timingLock.lock(); completedHostNS = hostNanoseconds(mach_absolute_time()); timingLock.unlock()
        }
        let commitHostNS = hostNanoseconds(mach_absolute_time())
        var resolveCommand: MTLCommandBuffer? = nil
        let makeDeferredResolve = {
            let resolve = queue.makeCommandBuffer()!
            resolve.label = "mechanism.resolve.\(iteration)"
            encodeResolve(resolve, drawable, indices, readback)
            resolve.commit()
            timingLock.lock(); resolveCommand = resolve; timingLock.unlock()
        }
        if deferredResolve == "enqueued" {
            let resolve = queue.makeCommandBuffer()!
            resolve.label = "mechanism.resolve.\(iteration)"
            encodeResolve(resolve, drawable, indices, readback)
            resolve.enqueue()
            command.commit()
            resolve.commit()
            resolveCommand = resolve
        } else if deferredResolve == "scheduled" {
            command.addScheduledHandler { _ in makeDeferredResolve() }
            command.commit()
        } else if deferredResolve == "completed" {
            command.addCompletedHandler { _ in makeDeferredResolve() }
            command.commit()
        } else {
            command.commit()
        }
        submits += 1

        let publicationGroup = DispatchGroup()
        var firstNewEndHostNS: UInt64 = 0
        var firstNewEnd: UInt64 = 0
        if publicationLatency {
            let oldEnd = priorCPUByIndex[indices.last!]
            publicationGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { publicationGroup.leave() }
                let deadline = hostNanoseconds(mach_absolute_time()) + 1_000_000_000
                while hostNanoseconds(mach_absolute_time()) < deadline {
                    if let resolved = try? sampleBuffer.resolveCounterRange(indices.last!..<(indices.last! + 1)) {
                        let value = resolved.withUnsafeBytes { $0.bindMemory(to: UInt64.self).first! }
                        if value != 0 && value != oldEnd {
                            timingLock.lock()
                            firstNewEnd = value
                            firstNewEndHostNS = hostNanoseconds(mach_absolute_time())
                            timingLock.unlock()
                            break
                        }
                    }
                    usleep(10)
                }
            }
        }
        command.waitUntilCompleted()
        publicationGroup.wait()
        if completedResolve {
            makeDeferredResolve()
        }
        var deferredCommand: MTLCommandBuffer? = nil
        while usesDeferred && deferredCommand == nil {
            timingLock.lock(); deferredCommand = resolveCommand; timingLock.unlock()
            if deferredCommand == nil { usleep(10) }
        }
        let terminal = deferredCommand ?? command
        terminal.waitUntilCompleted()
        if command.status == .error || terminal.status == .error { failures += 1 }

        let first = indices.min()!
        let count = indices.max()! - first + 1
        let words = readback.contents().bindMemory(to: UInt64.self, capacity: 128)
        let gpu = (0..<count).map { words[first + $0] }
        var cpu: [UInt64] = []
        if let resolved = try? sampleBuffer.resolveCounterRange(first..<(first + count)) {
            cpu = resolved.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
        }
        let begin = gpu.first ?? 0
        let end = gpu.last ?? 0
        let prior = (priorByIndex[indices[0]], priorByIndex[indices.last!])
        var record: [String: Any] = [
            "kind": "sample", "experiment": experiment, "iteration": iteration,
            "slot": iteration % slotCount, "indices": indices, "gpu_samples": gpu,
            "gpu_begin": begin, "gpu_end": end,
            "prior_begin": prior.0, "prior_end": prior.1, "prior_kind": prior.1 == 0 ? "" : "mapped",
            "class": terminal.status == .completed ? classify(begin: begin, end: end, prior: prior) : "failed_command",
            "cpu_samples": cpu, "status": terminal.status.rawValue,
            "error": terminal.error.map { "\($0)" } ?? "", "final_drain": true,
            "render_gpu_start_ns": UInt64(command.gpuStartTime * 1e9),
            "render_gpu_end_ns": UInt64(command.gpuEndTime * 1e9),
            "render_gpu_duration_ns": UInt64(max(0, command.gpuEndTime - command.gpuStartTime) * 1e9),
        ]
        if cpu.count == gpu.count {
            record["gpu_matches_cpu"] = cpu == gpu
            record["index_matches_cpu"] = zip(gpu, cpu).map(==)
            record["prior_cpu_samples"] = indices.map { priorCPUByIndex[$0] }
            record["index_stale"] = indices.enumerated().map { offset, index in
                gpu[offset] == priorCPUByIndex[index] && gpu[offset] != 0
            }
        }
        if gapDispatches > 0 {
            record["gap_gpu_begin"] = words[4]
            record["gap_gpu_end"] = words[5]
            record["gap_gpu_ns"] = words[5] > words[4] ? words[5] - words[4] : 0
        }
        emit(record)
        if publicationLatency {
            timingLock.lock()
            let scheduled = scheduledHostNS
            let completed = completedHostNS
            let firstNewHost = firstNewEndHostNS
            let firstNewSample = firstNewEnd
            timingLock.unlock()
            emit(["kind": "publication", "experiment": experiment, "iteration": iteration,
                  "commit_host_ns": commitHostNS, "scheduled_host_ns": scheduled,
                  "completed_host_ns": completed, "gpu_start_ns": UInt64(command.gpuStartTime * 1e9),
                  "gpu_end_ns": UInt64(command.gpuEndTime * 1e9),
                  "first_new_end_host_ns": firstNewHost, "end_sample_ns": firstNewSample,
                  "gpu_resolved_end": end])
        }
        for (offset, index) in indices.enumerated() {
            priorByIndex[index] = gpu[offset]
            if cpu.count == gpu.count { priorCPUByIndex[index] = cpu[offset] }
        }

        let present = queue.makeCommandBuffer()!
        present.present(drawable)
        present.commit()
    }
}
let clockEnd = device.sampleTimestamps()
emit(["kind": "footer", "experiment": experiment, "submits": submits,
      "command_failures": failures, "drained": true,
      "clock_end_cpu": clockEnd.cpu, "clock_end_cpu_ns": clockEnd.cpu,
      "clock_end_gpu": clockEnd.gpu, "source_sha256": sourceSHA,
      "executable_sha256": executableSHA])
output.closeFile()
