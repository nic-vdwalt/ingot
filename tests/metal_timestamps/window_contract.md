# Selected window replay contract, schema 9

This contract covers the complete built-in window pass, not arbitrary image/custom
shader draws or ocean passes. A missing input rejects reconstruction rather than
being replaced with a plausible default. The selected historical v5 failure has
three draws (1080, 66, 318 indices), all of which must be represented.

## GPU input layout

- Vertex stride 36 bytes; little-endian position Float32x2 at 0, color Float32x4
  at 8, UV Float32x2 at 24 and mode Uint32 at 32. Vertex step mode is per vertex.
- Index format Uint32; DrawIndexed uses instance count 1, first index 0, base
  vertex 0 and first instance 0. TriangleList topology, CCW front face, no culling.
- Projection is four f32 words in a 16-byte uniform buffer. Group 0 binding 0 is
  a vertex-visible Uniform with minimum binding size 16 and no dynamic offsets.
- Group 1 binding 0 is a vertex/fragment-visible float 2D texture. Binding 1 is a
  vertex/fragment-visible filtering sampler. A nil bind cannot be reconstructed
  by assuming the renderer's intended state: inherited binding evidence is absent.
- Built-in shader source is the actual schema-8 `batch_shader` string. Solid uses
  `vs_main` and `fs_ui`. Even mode Solid samples the texture before branching.
  Image and custom paths are outside the initial supported subset.

## Pipeline and attachments

Single-sample RGBA8Unorm (pinned enum 22) or BGRA8Unorm (27), all color write bits,
multisample mask 0xffffffff, no depth/stencil attachment. No viewport override was
found in gfx; default viewport covers the attachment. Each draw retains its actual
scissor, which must fit the recorded physical attachment extent.

Color and alpha use identical Add blending. Slots: Alpha = One/OneMinusSrcAlpha;
Additive = One/One; Multiplied = Dst/OneMinusSrcAlpha. Custom factors are not retained.
Output is premultiplied; the selected Unorm target does not add sRGB encoding.

Schema 9 exports `batch_pipelines`: the eight (kind x blend slot) descriptors
`_make_pipe` handed to the device, keyed `slot + kind * 4`, as pinned wgpu integer
values (vertex stride/attributes, step mode, primitive, multisample, blend color and
alpha components, write mask as the bit-set word). Only the first format recorded per
entry is retained, which is the swapchain set built by `renderer_init`; alt-format
sets never displace it. `replay_inputs.batch_pipeline` accepts a draw only when the
descriptor it selected is known, targets the record's attachment format and matches
the fixed batch contract exactly. The descriptor is captured from the running build,
but it is still not tied to immutable build provenance.

Window load is Clear (2), store is Store (1). Clear input is four original f64
words, not parsed human-readable JSON floats. Depth clear is an original f32 word,
although the selected window has no depth attachment. A Load pass cannot use zero
initial contents unless its producer or actual initial contents are reproduced.

## Texture reconstruction

Neutral: explicit matching nonnil neutral bind, 1×1 RGBA8Unorm, bytes ff ff ff ff.
Nearest min/mag/mipmap, ClampToEdge U/V/W, maxAnisotropy 1.

Atlas: 2048×2048 R8Unorm zero base, one mip and one sample. Apply tight retained R8
uploads in global upload order through the draw's submission prefix, selecting its
one-based atlas ID. Filter POINT (0) selects Nearest; all other declared filters
(1–5) select Linear min/mag in the inspected producer. Mipmap remains Nearest,
ClampToEdge U/V/W and maxAnisotropy 1. Later uploads must not be applied early.

The diagnostics owner retains at most 256 uploads and 1 MiB of tight pixels.
Global loss before submission makes atlas evidence unknown. Loss after submission
does not invalidate an earlier sealed prefix. Atlas bind rebuilding and resource
retirement are not permission to reinterpret an old bind using a new sampler.

## Identity and queue evidence

Keep epoch/frame/generation/request, physical slot/query pair, encoder creation ID,
submission attempt ordinal, resolve encoder/ordinal, callback status and collection
identity. Eight query slots each hold at most 64 pairs. Previous mapped values are
not native final CPU counter values and must remain separately labeled.

The current diagnostic hooks seal submission metadata before QueueSubmit; the
ordinal does not assert GPU success. Geometry uploads, projection writes, atlas
writes and other passes in the same command buffer affect topology. Capturing only
the window render descriptor is insufficient to claim exact queue replay.

## Readiness and remaining inputs

`window_readiness.py` is a conservative rejection report, not yet a replay bundle
exporter. It checks the retained subset and always reports these outstanding gates:

1. Immutable actual-build source/compiler/dependency/assets provenance, including
   the pipeline construction sources that accompany the exported WGSL.
2. Complete producer/resolve command topology for the selected game submission.

The archived `artifacts/timing-window-contract-v1/` and `-v2/` source snapshots and
SHA manifests establish what was inspected (v2 adds `gpu_timing_pipeline.odin` and
the schema 9 exporter state; the WGSL hash is unchanged), not what built a
historical or future game capture.
Historical v5 additionally lacks exact clears, shader text and all retained draw
geometry/texture input data. No fill-in operation can retroactively recover those.

No GPU replay, game root-cause attribution, callback retirement, transport health or
120 Hz qualification follows from passing CPU reconstruction tests.
