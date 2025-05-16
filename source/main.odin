package main

import "base:runtime"
import "base:intrinsics"
import t "core:time"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/ease"
import "core:mem"

import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

app_state: struct {
	pass_action: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,
}

window_w :: 1280
window_h :: 720

main :: proc() {
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		event_cb = event,
		width = window_w,
		height = window_h,
		window_title = "epic hot sauce",
		icon = { sokol_default = true },
		logger = { func = slog.func },
	})
}

init :: proc "c" () {
	using linalg, fmt
	context = runtime.default_context()
	
	init_time = t.now()
	last_frame_time = init_time

	sg.setup({
		environment = sglue.environment(),
		logger = { func = slog.func },
		d3d11_shader_debugging = ODIN_DEBUG,
	})
	
	init_images()
	init_fonts()
	
	// make the vertex buffer
	app_state.bind.vertex_buffers[0] = sg.make_buffer({
		usage = .DYNAMIC,
		size = size_of(Quad) * len(draw_frame.quads),
	})
	
	// make & fill the index buffer
	index_buffer_count :: MAX_QUADS*6
	indices : [index_buffer_count]u16;
	i := 0;
	for i < index_buffer_count {
		// vertex offset pattern to draw a quad
		// { 0, 1, 2,  0, 2, 3 }
		indices[i + 0] = auto_cast ((i/6)*4 + 0)
		indices[i + 1] = auto_cast ((i/6)*4 + 1)
		indices[i + 2] = auto_cast ((i/6)*4 + 2)
		indices[i + 3] = auto_cast ((i/6)*4 + 0)
		indices[i + 4] = auto_cast ((i/6)*4 + 2)
		indices[i + 5] = auto_cast ((i/6)*4 + 3)
		i += 6;
	}
	app_state.bind.index_buffer = sg.make_buffer({
		type = .INDEXBUFFER,
		data = { ptr = &indices, size = size_of(indices) },
	})
	
	// image stuff
	app_state.bind.samplers[SMP_default_sampler] = sg.make_sampler({})
	
	// setup pipeline
	pipeline_desc : sg.Pipeline_Desc = {
		shader = sg.make_shader(quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				ATTR_quad_position = { format = .FLOAT2 },
				ATTR_quad_color0 = { format = .FLOAT4 },
				ATTR_quad_uv0 = { format = .FLOAT2 },
				ATTR_quad_bytes0 = { format = .UBYTE4N },
				ATTR_quad_color_override0 = { format = .FLOAT4 }
			},
		}
	}
	blend_state : sg.Blend_State = {
		enabled = true,
		src_factor_rgb = .SRC_ALPHA,
		dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
		op_rgb = .ADD,
		src_factor_alpha = .ONE,
		dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		op_alpha = .ADD,
	}
	pipeline_desc.colors[0] = { blend = blend_state }
	app_state.pip = sg.make_pipeline(pipeline_desc)

	// default pass action
	app_state.pass_action = {
		colors = {
			0 = { load_action = .CLEAR, clear_value = { 0, 0, 0, 1 }},
		},
	}

	init_entities()
}

init_entities :: proc () {
	entity_create(.player)
	crawler : ^Entity = entity_create(.crawler)
	crawler.position = v2{-50, 50}
	player = entity_create(.tile)
	player.position = v2{50, 50}
}

//
// :frame
frame :: proc "c" () {
	using runtime, linalg
	context = runtime.default_context()
	
	memset(&draw_frame, 0, size_of(draw_frame)) // @speed, we probs don't want to reset this whole thing
	
	delta_time : f64 = sapp.frame_duration()
	update(delta_time)
	render()
	
	app_state.bind.images[IMG_tex0] = atlas.sg_image
	app_state.bind.images[IMG_tex1] = images[font.img_id].sg_img
	
	sg.update_buffer(
		app_state.bind.vertex_buffers[0],
		{ ptr = &draw_frame.quads[0], size = size_of(Quad) * len(draw_frame.quads) }
	)
	sg.begin_pass({ action = app_state.pass_action, swapchain = sglue.swapchain() })
	sg.apply_pipeline(app_state.pip)
	sg.apply_bindings(app_state.bind)
	sg.draw(0, 6*draw_frame.quad_count, 1)
	sg.end_pass()
	sg.commit()
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	sg.shutdown()
}

event :: proc "c" (a0: ^sapp.Event) {
	context = runtime.default_context()
	if (a0.type == .KEY_DOWN) {
        #partial switch (a0.key_code) {
            case .W:
				player.position.y = player.position.y + 100 * f32(sapp.frame_duration())
				break
			case .S:
				player.position.y = player.position.y - 100 * f32(sapp.frame_duration())
				break
			case .D:
				player.position.x = player.position.x + 100 * f32(sapp.frame_duration())
				break
			case .A:
				player.position.x = player.position.x - 100 * f32(sapp.frame_duration())
				break
		}
    }
}

//
// :UTILS

DEFAULT_UV :: v4{0, 0, 1, 1}
Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
v2 :: Vector2
v3 :: Vector3
v4 :: Vector4
Matrix4 :: linalg.Matrix4f32;

COLOR_WHITE :: Vector4 {1,1,1,1}

// might do something with these later on
loggie :: fmt.println // log is already used........
log_error :: fmt.println
log_warning :: fmt.println

init_time: t.Time
last_frame_time : t.Time
seconds_since_init :: proc() -> f64 {
	using t
	if init_time._nsec == 0 {
		log_error("invalid time")
		return 0
	}
	return duration_seconds(since(init_time))
}

xform_translate :: proc(pos: Vector2) -> Matrix4 {
	return linalg.matrix4_translate(v3{pos.x, pos.y, 0})
}
xform_rotate :: proc(angle: f32) -> Matrix4 {
	return linalg.matrix4_rotate(math.to_radians(angle), v3{0,0,1})
}
xform_scale :: proc(scale: Vector2) -> Matrix4 {
	return linalg.matrix4_scale(v3{scale.x, scale.y, 1});
}

Pivot :: enum {
	bottom_left,
	bottom_center,
	bottom_right,
	center_left,
	center_center,
	center_right,
	top_left,
	top_center,
	top_right,
}
scale_from_pivot :: proc(pivot: Pivot) -> Vector2 {
	switch pivot {
		case .bottom_left: return v2{0.0, 0.0}
		case .bottom_center: return v2{0.5, 0.0}
		case .bottom_right: return v2{1.0, 0.0}
		case .center_left: return v2{0.0, 0.5}
		case .center_center: return v2{0.5, 0.5}
		case .center_right: return v2{1.0, 0.5}
		case .top_center: return v2{0.5, 1.0}
		case .top_left: return v2{0.0, 1.0}
		case .top_right: return v2{1.0, 1.0}
	}
	return {};
}

sine_breathe :: proc(p: $T) -> T where intrinsics.type_is_float(T) {
	return (math.sin((p - .25) * 2.0 * math.PI) / 2.0) + 0.5
}

//
// :RENDER STUFF
//
// API ordered highest -> lowest level

draw_sprite :: proc(pos: Vector2, img_id: Image_Id, pivot:= Pivot.bottom_left, xform := Matrix4(1), color_override:= v4{0,0,0,0}, size_override := Vector2{0, 0}) {
	image := images[img_id]
	size := v2{auto_cast image.width, auto_cast image.height}
	
	if(size_override != Vector2{0, 0})
	{
		size = v2{auto_cast size_override.x, auto_cast size_override.y}
	}

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform // we slide in here because rotations + scales work nicely at this point
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))
	
	draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col, uv, img_id, color_override)
}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
) {
	draw_rect_projected(draw_frame.projection * draw_frame.camera_xform * xform, size, col, uv, img_id, color_override)
}

Vertex :: struct {
	pos: Vector2,
	col: Vector4,
	uv: Vector2,
	tex_index: u8,
	_pad: [3]u8,
	color_override: Vector4,
}

Quad :: [4]Vertex;

MAX_QUADS :: 8192
MAX_VERTS :: MAX_QUADS * 4

Draw_Frame :: struct {

	quads: [MAX_QUADS]Quad,
	quad_count: int,
	
	projection: Matrix4,
	camera_xform: Matrix4,

}
draw_frame : Draw_Frame;

// below is the lower level draw rect stuff

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0}
) {

	bl := v2{ 0, 0 }
	tl := v2{ 0, size.y }
	tr := v2{ size.x, size.y }
	br := v2{ size.x, 0 }
	
	uv0 := uv
	if uv == DEFAULT_UV {
		uv0 = images[img_id].atlas_uvs
	}
	
	tex_index :u8= images[img_id].tex_index
	if img_id == .nil {
		tex_index = 255 // bypasses texture sampling
	}
	
	draw_quad_projected(world_to_clip, {bl, tl, tr, br}, {col, col, col, col}, {uv0.xy, uv0.xw, uv0.zw, uv0.zy}, {tex_index,tex_index,tex_index,tex_index}, {color_override,color_override,color_override,color_override})

}

draw_quad_projected :: proc(
	world_to_clip:   Matrix4, 
	positions:       [4]Vector2,
	colors:          [4]Vector4,
	uvs:             [4]Vector2,
	tex_indicies:       [4]u8,
	//flags:           [4]Quad_Flags,
	color_overrides: [4]Vector4,
	//hsv:             [4]Vector3
) {
	using linalg

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}
		
	verts := cast(^[4]Vertex)&draw_frame.quads[draw_frame.quad_count];
	draw_frame.quad_count += 1;
	
	verts[0].pos = (world_to_clip * Vector4{positions[0].x, positions[0].y, 0.0, 1.0}).xy
	verts[1].pos = (world_to_clip * Vector4{positions[1].x, positions[1].y, 0.0, 1.0}).xy
	verts[2].pos = (world_to_clip * Vector4{positions[2].x, positions[2].y, 0.0, 1.0}).xy
	verts[3].pos = (world_to_clip * Vector4{positions[3].x, positions[3].y, 0.0, 1.0}).xy
	
	verts[0].col = colors[0]
	verts[1].col = colors[1]
	verts[2].col = colors[2]
	verts[3].col = colors[3]

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]
	
	verts[0].tex_index = tex_indicies[0]
	verts[1].tex_index = tex_indicies[1]
	verts[2].tex_index = tex_indicies[2]
	verts[3].tex_index = tex_indicies[3]
	
	verts[0].color_override = color_overrides[0]
	verts[1].color_override = color_overrides[1]
	verts[2].color_override = color_overrides[2]
	verts[3].color_override = color_overrides[3]
}

//
// :IMAGE STUFF
//
Image_Id :: enum {
	nil,
	player,
	crawler,
	playertile,
}

Image :: struct {
	width, height: i32,
	tex_index: u8,
	sg_img: sg.Image,
	data: [^]byte,
	atlas_uvs: Vector4,
}
images: [128]Image
image_count: int

init_images :: proc() {
	using fmt

	img_dir := "res/images/"
	
	highest_id := 0;
	for img_name, id in Image_Id {
		if id == 0 { continue }
		
		if id > highest_id {
			highest_id = id
		}
		
		path := tprint(img_dir, img_name, ".png", sep="")
		png_data, succ := os.read_entire_file(path)
		fmt.printfln("on image id: %v", img_name)
		assert(succ)
		
		stbi.set_flip_vertically_on_load(1)
		width, height, channels: i32
		img_data := stbi.load_from_memory(raw_data(png_data), auto_cast len(png_data), &width, &height, &channels, 4)
		assert(img_data != nil, "stbi load failed, invalid image?")
			
		img : Image;
		img.width = width
		img.height = height
		img.data = img_data
		
		images[id] = img
	}
	image_count = highest_id + 1
	
	pack_images_into_atlas()
}

Atlas :: struct {
	w, h: int,
	sg_image: sg.Image,
}
atlas: Atlas
// We're hardcoded to use just 1 atlas now since I don't think we'll need more
// It would be easy enough to extend though. Just add in more texture slots in the shader
pack_images_into_atlas :: proc() {

	// TODO - add a single pixel of padding for each so we avoid the edge oversampling issue

	// 8192 x 8192 is the WGPU recommended max I think
	atlas.w = 128
	atlas.h = 128
	
	cont : stbrp.Context
	nodes : [128]stbrp.Node // #volatile with atlas.w
	stbrp.init_target(&cont, auto_cast atlas.w, auto_cast atlas.h, &nodes[0], auto_cast atlas.w)
	
	rects : [dynamic]stbrp.Rect
	for img, id in images {
		if img.width == 0 {
			continue
		}
		append(&rects, stbrp.Rect{ id=auto_cast id, w=auto_cast img.width, h=auto_cast img.height })
	}
	
	succ := stbrp.pack_rects(&cont, &rects[0], auto_cast len(rects))
	if succ == 0 {
		assert(false, "failed to pack all the rects, ran out of space?")
	}
	
	// allocate big atlas
	raw_data, err := mem.alloc(atlas.w * atlas.h * 4)
	defer mem.free(raw_data)
	mem.set(raw_data, 255, atlas.w*atlas.h*4)
	
	// copy rect row-by-row into destination atlas
	for rect in rects {
		img := &images[rect.id]
		
		// copy row by row into atlas
		for row in 0..<rect.h {
			src_row := mem.ptr_offset(&img.data[0], row * rect.w * 4)
			dest_row := mem.ptr_offset(cast(^u8)raw_data, ((rect.y + row) * auto_cast atlas.w + rect.x) * 4)
			mem.copy(dest_row, src_row, auto_cast rect.w * 4)
		}
		
		// yeet old data
		stbi.image_free(img.data)
		img.data = nil;
		
		// img.atlas_x = auto_cast rect.x
		// img.atlas_y = auto_cast rect.y
		
		img.atlas_uvs.x = cast(f32)rect.x / cast(f32)atlas.w
		img.atlas_uvs.y = cast(f32)rect.y / cast(f32)atlas.h
		img.atlas_uvs.z = img.atlas_uvs.x + cast(f32)img.width / cast(f32)atlas.w
		img.atlas_uvs.w = img.atlas_uvs.y + cast(f32)img.height / cast(f32)atlas.h
	}
	
	stbi.write_png("atlas.png", auto_cast atlas.w, auto_cast atlas.h, 4, raw_data, 4 * auto_cast atlas.w)
	
	// setup image for GPU
	desc : sg.Image_Desc
	desc.width = auto_cast atlas.w
	desc.height = auto_cast atlas.h
	desc.pixel_format = .RGBA8
	desc.data.subimage[0][0] = {ptr=raw_data, size=auto_cast (atlas.w*atlas.h*4)}
	atlas.sg_image = sg.make_image(desc)
	if atlas.sg_image.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
}

//
// :FONT
//
draw_text :: proc(pos: Vector2, text: string, scale:= 1.0) {
	using stbtt
	
	x: f32
	y: f32

	for char in text {
		
		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(&font.char_data[0], font_bitmap_w, font_bitmap_h, cast(i32)char - 32, &advance_x, &advance_y, &q, false)
		// this is the the data for the aligned_quad we're given, with y+ going down
		// x0, y0,     s0, t0, // top-left
		// x1, y1,     s1, t1, // bottom-right
		
		
		size := v2{ abs(q.x0 - q.x1), abs(q.y0 - q.y1) }
		
		bottom_left := v2{ q.x0, -q.y1 }
		top_right := v2{ q.x1, -q.y0 }
		assert(bottom_left + size == top_right)
		
		offset_to_render_at := v2{x,y} + bottom_left
		
		uv := v4{ q.s0, q.t1,
							q.s1, q.t0 }
		
		xform := Matrix4(1)
		xform *= xform_translate(pos)
		xform *= xform_scale(v2{auto_cast scale, auto_cast scale})
		xform *= xform_translate(offset_to_render_at)
		draw_rect_xform(xform, size, uv=uv, img_id=font.img_id)
		
		x += advance_x
		y += -advance_y
	}

}

font_bitmap_w :: 256
font_bitmap_h :: 256
char_count :: 96
Font :: struct {
	char_data: [char_count]stbtt.bakedchar,
	img_id: Image_Id,
}
font: Font

init_fonts :: proc() {
	using stbtt
	
	bitmap, _ := mem.alloc(font_bitmap_w * font_bitmap_h)
	font_height := 15 // for some reason this only bakes properly at 15 ? it's a 16px font dou...
	path := "res/fonts/alagard.ttf"
	ttf_data, err := os.read_entire_file(path)
	assert(ttf_data != nil, "failed to read font")
	
	ret := BakeFontBitmap(raw_data(ttf_data), 0, auto_cast font_height, auto_cast bitmap, font_bitmap_w, font_bitmap_h, 32, char_count, &font.char_data[0])
	assert(ret > 0, "not enough space in bitmap")
	
	stbi.write_png("font.png", auto_cast font_bitmap_w, auto_cast font_bitmap_h, 1, bitmap, auto_cast font_bitmap_w)
	
	// setup font atlas so we can use it in the shader
	desc : sg.Image_Desc
	desc.width = auto_cast font_bitmap_w
	desc.height = auto_cast font_bitmap_h
	desc.pixel_format = .R8
	desc.data.subimage[0][0] = {ptr=bitmap, size=auto_cast (font_bitmap_w*font_bitmap_h)}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
	
	id := store_image(font_bitmap_w, font_bitmap_h, 1, sg_img)
	font.img_id = id
}
// kind scuffed...
// but I'm abusing the Images to store the font atlas by just inserting it at the end with the next id
store_image :: proc(w: int, h: int, tex_index: u8, sg_img: sg.Image) -> Image_Id {

	img : Image
	img.width = auto_cast w
	img.height = auto_cast h
	img.tex_index = tex_index
	img.sg_img = sg_img
	img.atlas_uvs = DEFAULT_UV
	
	id := image_count
	images[id] = img
	image_count += 1
	
	return auto_cast id
}

/*
ENTITY MEGASTRUCT
by randy.gg
This is an extremely simple and flexible entity structure for video games that doesn't make you want to
die when you're 20k lines deep in a project.
pros:
- you never have to think about the ideal entity structure again and can get back to working on things that
actually matter (actually using it to add new entities and making your game better, instead of overthinking)
- has all of the reuse power of an Entity Component System (ECS)
- doesn't have the complexity of an ECS
- you don't have to think about where to put that one new piece of data you need while in the middle of gameplay programming
- you can do easy serialisation by just copying the bytes over
cons:
- it seems "messy" and wasteful
- probably won't get you laid
If you're heavily memory constrained, you'll probs want to upgrade this into a discriminated union with a shared Entity base
structure. Or even dynamically allocate each new entity. But that comes with extra complexity. Don't pay it unless you have to.
I used it in these games:
https://store.steampowered.com/app/2571560/ARCANA/
https://store.steampowered.com/app/3309460/Demon_Knives/ (we used the more complicated variation I mentioned earlier,
except it was probably overkill in hindsight)
https://store.steampowered.com/app/3433610/Terrafactor/
It holds up incredibly well, even as you scale it up.
I got this idea from Ryan Fleury a few years ago. Been using it every single day ever since.
---
This is Odin style pseduo-code and won't actually compile.
There's a few missing pieces and extra things you need when scaling this up, but it's a good enough overview to
get the point across.
*/

//
// the data structures
//

// you can crank this however high you want. In Terrafactor I've got mine at 65,536 (with some extra things for
// looping over them properly)
MAX_ENTITIES :: 1024

game_state: Game_State
Game_State :: struct {
	initialized: bool,
	entities: [MAX_ENTITIES]Entity,
	entity_id_gen: u64,
	entity_top_count: u64,
	world_name: string,
	player_handle: Entity_Handle,
}

player: ^Entity

Entity_Kind :: enum {
	nil,
	player,
	crawler,
	tile,
}

Entity :: struct {
	allocated: bool,
	handle: Entity_Handle,
	kind: Entity_Kind,

	// could pack these into flags if you feel like it (not really needed though)
	has_physics: bool,
	damagable_by_player: bool,
	is_mob: bool,
	blocks_mobs: bool,

	// just put whatever state you need in here to make the game...
	position: Vector2,
	velocity: Vector2,
	rotation: Matrix4,
	acceleration: Vector2,
	hitbox: Vector4,
	hit_cooldown_end_time: f64,
	health: u64,
	next_attack_time: f64,
	sprite_id: Image_Id,
	current_animation_frame: u64,
	// ...

	// Constant Entity Data
	//
	// this is constant based on the kind of the entity
	// you could put this somewhere else if you want, I like having it inside the entity for easy access though.
	// the 'using' is Odin/Jai specific and just makes it so you can:
	// 'entity.max_health' instead of 'entity.const_data.max_health'
	//
	using const_data: Const_Entity_Data,
}

Const_Entity_Data :: struct {
	update: proc(^Entity),
	draw: proc(^Entity),

	icon_image: Image_Id,
	max_health: u64, // you could move this back into the Entity struct to make it dynamic, and no existing code would break
}

//
// creating / destroying
//

entity_create :: proc(kind: Entity_Kind) -> ^Entity {

	// look through game_state.entities and grab the first one that isnt 'allocated'
	// (could also use a free list, and use straight from entity_top_count when that's empty)
	new_index : int = -1
	new_entity: ^Entity = nil
	for &entity, index in game_state.entities {
		if !entity.allocated {
			new_entity = &entity
			new_index = int(index)
			break
		}
	}
	if new_index == -1 {
		log_error("out of entities, probably just double the MAX_ENTITIES")
		return nil
	}

	game_state.entity_top_count += 1
	
	// then set it up
	new_entity.allocated = true

	game_state.entity_id_gen += 1
	new_entity.handle.id = game_state.entity_id_gen
	new_entity.handle.index = u64(new_index)

	// could add whatever defaults in here
	// todo : uncomment
	new_entity.draw = default_draw_based_on_entity_data

	new_entity.rotation = Matrix4(1)

	switch kind {
		case .nil: break
		case .player: setup_player(new_entity)
		case .crawler: setup_crawler(new_entity)
		case .tile: setup_tile(new_entity)
	}

	return new_entity
}

entity_destroy :: proc(entity: ^Entity) {
	entity^ = {} // it's really that simple
}

//
// handles
//

// Use this for storing entities instead of pointers for any long-ish period of time.
// If you're holding a pointer, and the thing has a chance of being destroyed, use a handle
// instead so it doesn't kill your game.

Entity_Handle :: struct {
	index: u64,
	id: u64,
}

entity_to_handle :: proc(entity: ^Entity) -> Entity_Handle {
	return entity.handle
}

//
// Having a zero return value (instead of using a null pointer) is a very useful concept for not having to
// deal with null pointer crashes.
// (more on this below)
//
@(rodata) // marks this as read-only data, crashes when you try to write.
zero_entity: Entity

handle_to_entity :: proc(handle: Entity_Handle) -> ^Entity {
	if handle == {} {
		return &zero_entity
	}

	entity := &game_state.entities[handle.index] // might wanna do some extra bounds checks on this first
	if entity.handle.id == handle.id {
		return entity
	} else {
		// the entity has been destroyed, and there's a new one in this slot
		return &zero_entity
	}
}
//
// When you get &zero_entity in a return value, instead of a null pointer, you can safely access it.
// Since the entire thing is zeroed, a lot of your logic / algorithms will just gracefully fail.
//
/* for example
handle_that_is_invalid := Entity_Handle{}
entity := handle_to_entity(handle_that_is_invalid)
if entity.allocated { // this won't crash, just read a zero and gracefully skip
	do_something()
}
*/


//
// SETUP (where the content magic happens)
// 

//
// The setup is designed to write into both the main dynamic Entity structure
// and the Const_Entity_Data structure.
//
// That way everything you need to add a new piece of content, ie - an enemy, build, item, etc
// ... is all localised in the one place.
//
// This becomes very important for the speed of adding new stuff in. What I usually do is just copy from the
// most similar existing entity as a starting point.
//

setup_player :: proc(entity: ^Entity) {
	entity.kind = .player
	entity.has_physics = true

	entity.max_health = 100

	entity.icon_image = .player;

	// update function is also nice and localised here
	entity.update = proc(entity: ^Entity) {
		entity.health = entity.max_health
	}

	entity.draw = proc(entity: ^Entity) {
		default_draw_based_on_entity_data(entity)
		
		// could add extra stuff to the draw like a sword or other items in the player's hand
		// ...
	}
}

setup_crawler :: proc(entity: ^Entity) {
	entity.kind = .crawler
	entity.has_physics = true

	entity.max_health = 100

	entity.icon_image = .crawler;

	// update function is also nice and localised here
	entity.update = proc(entity: ^Entity) {
		entity.health = entity.max_health
		alpha :f32= auto_cast math.mod(seconds_since_init() * 0.2, 1.0)
		entity.rotation = xform_rotate(alpha * 360.0)
		entity.rotation *= xform_scale(1.0 + 1 * sine_breathe(alpha))
	}

	entity.draw = proc(entity: ^Entity) {
		default_draw_based_on_entity_data(entity)
	}
}

setup_tile :: proc(entity: ^Entity) {
	entity.kind = .tile
	entity.has_physics = true

	entity.icon_image = .playertile;

	// update function is also nice and localised here
	entity.update = proc(entity: ^Entity) {
		entity.health = entity.max_health
	}

	entity.draw = proc(entity: ^Entity) {
		draw_sprite(entity.position, entity.icon_image, xform=entity.rotation, pivot=.bottom_center)
	}
}

default_draw_based_on_entity_data :: proc(e: ^Entity) {
	// draw_sprite stuff based on e.pos, e.sprite_id, etc ...

	draw_sprite(e.position, e.icon_image, xform=e.rotation, pivot=.bottom_center)
}

//
// main entry, update, and rendering
//

update :: proc(delta_t: f64) {

	for &entity in game_state.entities {
		if !entity.allocated do continue

		// call the update function
		entity.update(&entity)

		if entity.has_physics {
			// do some epic physics stuff (topic for another day)
			/*entity.vel += entity.acc * delta_t
			entity.pos += entity.vel * delta_t
			entity.acc = 0*/

			// could do some collision resolution stuff in here...
		}

		// you might even want to split the update into pre-physics and post-physics
		// entity.post_physics_update(entity)
	}

	// could do some other stuff out here
	// Like if things every become slow inside an entity update, break them out and optimise
	// a larger all-in-one pass
	for entity in game_state.entities {
		// ... do some operation in bulk on them or something
	}

}

// (a very incomplete example, just showing off the entity draw)
render :: proc() {
	using linalg

	draw_frame.projection = matrix_ortho3d_f32(window_w * -0.5, window_w * 0.5, window_h * -0.5, window_h * 0.5, -1, 1)
	
	draw_frame.camera_xform = Matrix4(1)
	draw_frame.camera_xform *= xform_scale(2)

	for &entity in game_state.entities {
		if !entity.allocated do continue

		entity.draw(&entity)
	}

	draw_text(v2{50, 0}, "sugon", scale=4.0)
}