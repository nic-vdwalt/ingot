#+build !js
// ingot:gfx - deterministic GPU readback of a render target to a PNG file.
//
// Why a render target and not the window: the surface is configured
// RenderAttachment-only (context.odin, SurfaceConfiguration.usage), and adding
// CopySrc there is adapter-dependent. Render-target textures carry CopySrc
// unconditionally (texture.odin, _new_rt_color), so every capture routes
// through BeginTextureMode..EndTextureMode and reads the resulting texture.
//
// Orientation: render targets store bottom-left origin (RT_PROJECTION_Y_FLIP,
// render_target.odin), matching raylib. PNG rows are top-down, so the unpad
// step reverses row order - a capture is upright without the negative source
// height a blit needs.
//
// Determinism: the same frame state produces byte-identical output on every
// backend, which is what makes captured media reproducible in CI and reusable
// as a visual-regression fence later.
package gfx

import "base:runtime"
import "core:strings"
import stbi "vendor:stb/image"
import wg "vendor:wgpu"

// WebGPU requires buffer copy rows to be a multiple of 256 bytes.
SCREENSHOT_ROW_ALIGNMENT :: 256
// Bounded wait for the staging map. Each DevicePoll blocks until the device has
// progressed, so this cap only exists to keep a lost device from hanging.
SCREENSHOT_MAX_POLLS :: 4096
// Guards against an absurd allocation from a corrupt target extent.
SCREENSHOT_MAX_PIXELS :: 64 * 1024 * 1024

// _screenshot_padded_bpr rounds a row's byte width up to the copy alignment.
@(private)
_screenshot_padded_bpr :: proc "contextless" (width: int) -> int {
	unpadded := width * 4
	remainder := unpadded % SCREENSHOT_ROW_ALIGNMENT
	if remainder == 0 do return unpadded
	return unpadded + (SCREENSHOT_ROW_ALIGNMENT - remainder)
}

// _screenshot_swizzle_needed reports whether `format` needs a BGRA to RGBA
// swap before PNG encoding. ok is false for any format this path cannot encode
// truthfully - callers must fail rather than write mislabelled pixels.
@(private)
_screenshot_swizzle_needed :: proc "contextless" (
	format: wg.TextureFormat,
) -> (
	needed: bool,
	ok: bool,
) {
	#partial switch format {
	case .BGRA8Unorm, .BGRA8UnormSrgb:
		return true, true
	case .RGBA8Unorm, .RGBA8UnormSrgb:
		return false, true
	}
	return false, false
}

// _screenshot_unpad_flip copies `height` padded source rows into tightly packed
// destination rows in reverse order, converting the render target's bottom-left
// origin into PNG's top-down row order.
@(private)
_screenshot_unpad_flip :: proc(src: []u8, dst: []u8, width, height, padded_bpr: int) -> bool {
	assert(width >= 0, "_screenshot_unpad_flip: negative width")
	assert(height >= 0, "_screenshot_unpad_flip: negative height")
	if width == 0 || height == 0 do return false
	row := width * 4
	if padded_bpr < row do return false
	if len(src) < padded_bpr * height do return false
	if len(dst) != row * height do return false
	for y in 0 ..< height {
		src_start := (height - 1 - y) * padded_bpr
		dst_start := y * row
		assert(src_start + row <= len(src), "_screenshot_unpad_flip: source overrun")
		assert(dst_start + row <= len(dst), "_screenshot_unpad_flip: destination overrun")
		copy(dst[dst_start:dst_start + row], src[src_start:src_start + row])
	}
	return true
}

// _screenshot_bgra_to_rgba swaps the red and blue channels in place. Applying
// it twice restores the original bytes, which is what the unit test asserts.
@(private)
_screenshot_bgra_to_rgba :: proc(pixels: []u8) -> bool {
	assert(len(pixels) >= 0, "_screenshot_bgra_to_rgba: negative length")
	if len(pixels) == 0 || len(pixels) % 4 != 0 do return false
	count := len(pixels) / 4
	for i in 0 ..< count {
		base := i * 4
		assert(base + 2 < len(pixels), "_screenshot_bgra_to_rgba: pixel overrun")
		pixels[base], pixels[base + 2] = pixels[base + 2], pixels[base]
	}
	return true
}

@(private)
Screenshot_Map :: struct {
	done:   bool,
	status: wg.MapAsyncStatus,
}

@(private)
_screenshot_map_done :: proc "c" (
	status: wg.MapAsyncStatus,
	message: wg.StringView,
	userdata1, userdata2: rawptr,
) {
	context = runtime.default_context()
	state := cast(^Screenshot_Map)userdata1
	if state == nil do return
	state.status = status
	state.done = true
}

// _screenshot_copy copies the whole texture into a fresh MapRead staging buffer
// and submits that copy. The caller owns the returned buffer.
@(private)
_screenshot_copy :: proc(
	ctx: ^Context,
	texture: wg.Texture,
	width, height, padded_bpr: int,
) -> wg.Buffer {
	assert(ctx != nil, "_screenshot_copy: nil context")
	assert(texture != nil, "_screenshot_copy: nil texture")
	assert(padded_bpr >= width * 4, "_screenshot_copy: row alignment underflow")
	staging := wg.DeviceCreateBuffer(
		ctx.device,
		&{usage = {.CopyDst, .MapRead}, size = u64(padded_bpr * height)},
	)
	if staging == nil do return nil
	encoder := wg.DeviceCreateCommandEncoder(ctx.device, nil)
	if encoder == nil {
		wg.BufferRelease(staging)
		return nil
	}
	source := wg.TexelCopyTextureInfo {
		texture = texture,
		aspect  = .All,
	}
	destination := wg.TexelCopyBufferInfo {
		buffer = staging,
		layout = {bytesPerRow = u32(padded_bpr), rowsPerImage = u32(height)},
	}
	extent := wg.Extent3D{u32(width), u32(height), 1}
	wg.CommandEncoderCopyTextureToBuffer(encoder, &source, &destination, &extent)
	command := wg.CommandEncoderFinish(encoder, nil)
	wg.QueueSubmit(ctx.queue, {command})
	wg.CommandBufferRelease(command)
	wg.CommandEncoderRelease(encoder)
	return staging
}

// _screenshot_map blocks until `staging` is host-readable. The poll count is
// capped so a lost device fails instead of hanging the capture process.
@(private)
_screenshot_map :: proc(ctx: ^Context, staging: wg.Buffer, size: int) -> bool {
	assert(ctx != nil, "_screenshot_map: nil context")
	assert(staging != nil, "_screenshot_map: nil staging buffer")
	assert(size > 0, "_screenshot_map: empty mapping")
	state := Screenshot_Map{}
	wg.BufferMapAsync(
		staging,
		{.Read},
		0,
		uint(size),
		{mode = .AllowProcessEvents, callback = _screenshot_map_done, userdata1 = &state},
	)
	for _ in 0 ..< SCREENSHOT_MAX_POLLS {
		if state.done do return state.status == .Success
		wg.DevicePoll(ctx.device, true, nil)
	}
	return false
}

// _screenshot_pixels reads `target` back into an owned, tightly packed, upright
// RGBA8 buffer. Returns ok=false without allocating when the target is invalid,
// its format is not encodable, or the GPU readback fails.
@(private)
context_screenshot_pixels :: proc(
	ctx: ^Context,
	target: RenderTexture2D,
) -> (
	pixels: []u8,
	ok: bool,
) {
	assert(ctx != nil, "context_screenshot_pixels: nil context")
	if !ctx.initialized do return nil, false
	entry := context_get_texture(ctx, target.texture.id)
	if entry == nil do return nil, false
	assert(entry.tex != nil, "_screenshot_pixels: registered entry without a texture")
	width, height := int(entry.width), int(entry.height)
	if width <= 0 || height <= 0 do return nil, false
	if width * height > SCREENSHOT_MAX_PIXELS do return nil, false
	swizzle, encodable := _screenshot_swizzle_needed(entry.wgformat)
	if !encodable do return nil, false

	padded_bpr := _screenshot_padded_bpr(width)
	staging := _screenshot_copy(ctx, entry.tex, width, height, padded_bpr)
	if staging == nil do return nil, false
	defer {
		wg.BufferDestroy(staging)
		wg.BufferRelease(staging)
	}
	size := padded_bpr * height
	if !_screenshot_map(ctx, staging, size) do return nil, false
	mapped := wg.BufferGetConstMappedRange(staging, 0, uint(size))
	if mapped == nil do return nil, false

	out := make([]u8, width * height * 4)
	unpacked := _screenshot_unpad_flip(mapped, out, width, height, padded_bpr)
	wg.BufferUnmap(staging)
	if !unpacked {
		delete(out)
		return nil, false
	}
	if swizzle && !_screenshot_bgra_to_rgba(out) {
		delete(out)
		return nil, false
	}
	return out, true
}

// SaveRenderTexturePng reads `target` back from the GPU and writes it to `path`
// as an upright RGBA8 PNG. Returns false when the target is invalid, its format
// is not encodable, the readback fails, or the file cannot be written.
//
// Call it outside BeginTextureMode..EndTextureMode: EndTextureMode submits the
// target's pass, so the contents are complete by the time this copy runs.
context_save_render_texture_png :: proc(
	ctx: ^Context,
	target: RenderTexture2D,
	path: string,
) -> bool {
	assert(ctx != nil, "context_save_render_texture_png: nil context")
	assert(len(path) > 0, "context_save_render_texture_png: empty path")
	assert(
		target.texture.id != 0 || target.id == 0,
		"context_save_render_texture_png: torn target handle",
	)
	if len(path) == 0 do return false
	pixels, ok := context_screenshot_pixels(ctx, target)
	if !ok do return false
	defer delete(pixels)
	entry := context_get_texture(ctx, target.texture.id)
	if entry == nil do return false
	assert(len(pixels) == int(entry.width) * int(entry.height) * 4)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	written := stbi.write_png(
		c_path,
		entry.width,
		entry.height,
		4,
		raw_data(pixels),
		entry.width * 4,
	)
	return written != 0
}

SaveRenderTexturePng :: proc(target: RenderTexture2D, path: string) -> bool {
	return context_save_render_texture_png(default_context(), target, path)
}
