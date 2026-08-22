package gfx

Capabilities :: struct {
	gpu_3d:          bool,
	raylib_meshes:   bool,
	default_text:    bool,
	path_textures:   bool,
	ime_positioning: bool,
	window_controls: bool,
	render_targets:             bool,
	compute:                    bool,
	storage_buffers:            bool,
	storage_textures:           bool,
	mip_generation:             bool,
	sampleable_depth:           bool,
	multiple_color_attachments: bool,
	general_rlgl:               bool,
}

capabilities :: proc() -> Capabilities {
	result := Capabilities {
		gpu_3d          = true,
		raylib_meshes   = false,
		path_textures   = ODIN_OS != .JS,
		ime_positioning = ODIN_OS == .Darwin || ODIN_OS == .Windows,
		window_controls = ODIN_OS != .JS,
		render_targets             = true,
		compute                    = true,
		storage_buffers            = true,
		storage_textures           = true,
		mip_generation             = false,
		sampleable_depth           = true,
		multiple_color_attachments = false,
		general_rlgl               = false,
	}
	when INGOT_DEFAULT_FONT do result.default_text = true
	return result
}
