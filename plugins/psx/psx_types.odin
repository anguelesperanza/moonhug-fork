package psx

// The PSX renderer's vocabulary: the enums and structs the components, the
// state and the render steps share. Ported from the single-file raylib
// framework (psx/psx.odin); the names are kept so its API reads the same.

// The width of the low-res frame, set to the sizes the PlayStation could
// output. NONE renders at the window's size.
Resolution :: enum u8 {
	RES_ONE,
	RES_TWO,
	RES_THREE,
	RES_FOUR,
	RES_FIVE,
	NONE,
}

// The vertical mode: the frame's height. P is progressive, I interlaced (each
// frame redraws alternate lines, see PsxView.interlacing). NONE renders at
// the window's height.
Mode :: enum u8 {
	NTCS_P,
	NTCS_I,
	PAL_P,
	PAL_I,
	NONE,
}

// How the low-res frame is fitted to the window. In every mode the camera
// projects for the shape the frame is shown at, so geometry is never squashed
// (a 256x240 frame shown at 4:3 or 16:9 has non-square pixels, as on a TV).
//
//   FOUR_THREE  pillarboxed to 4:3, like a PS1 on a CRT; bars fill the rest
//   STRETCH     fills the window: the same pixel count spread wider
//   WIDESCREEN  fills the window with the frame widened to match its shape
//               (256x240 -> 341x240 at 16:9): pixels keep the shape they
//               would have on a 4:3 TV and the camera sees more to the sides
Display_Aspect :: enum u8 {
	FOUR_THREE,
	STRETCH,
	WIDESCREEN,
}

// The PS1 only had affine texture mapping; perspective-correct is here because
// it is easier on the eyes.
Texture_Mode :: enum u8 {
	AFFINE,
	PERSPECTIVE,
}

Color_Depth :: enum u8 {
	BITS_15,
	BITS_24,
}

// The PS1's semi-transparency modes, B the frame behind and F the object:
// HALF 0.5B + 0.5F, ADD B + F, SUBTRACT B - F, QUARTER_ADD B + 0.25F.
Blend_Mode :: enum u8 {
	OPAQUE,
	HALF,
	ADD,
	SUBTRACT,
	QUARTER_ADD,
}

// How an object is lit. BAKED is for level geometry: the lights are folded
// into vertex colours when the level draws first. LIVE is for things that move:
// the three strongest lights as directional lights per object, evaluated per
// vertex's normal. UNLIT shows the texture as it is.
Lighting_Mode :: enum u8 {
	BAKED,
	LIVE,
	UNLIT,
}

Light_Kind :: enum u8 {
	DIRECTIONAL,
	POINT,
	SPOT,
	AREA_RECT,
	AREA_DISK,
}

Ambient_Kind :: enum u8 {
	CONSTANT,
	HEMISPHERE,
}

Text_Space :: enum u8 {
	FRAME,  // into the low-res frame: gets the post effects, lands on its pixels
	SCREEN, // on top, at the window's resolution
}

Fps_Mode :: enum u8 {
	NTSC, // 30 fps
	PAL,  // 25 fps
}

// The CRT pass: all of them 0 (and overscan off) is no pass at all.
Post_Effects :: struct {
	blur:      f32 `decor:range(0, 1)`, // composite blur / colour bleed
	scanlines: f32 `decor:range(0, 1)`,
	curvature: f32 `decor:range(0, 0.5)`,
	vignette:  f32 `decor:range(0, 1)`,
	mask:      f32 `decor:range(0, 1)`, // aperture-grille stripes
	overscan:  bool,                    // zooms the curved picture to fill the screen
}

POST_EFFECTS_CRT :: Post_Effects{
	blur      = 0.6,
	scanlines = 0.5,
	curvature = 0.08,
	vignette  = 0.4,
	mask      = 0.3,
}

// One light as the baker and the live lighting see it, in world space.
Light :: struct {
	kind:        Light_Kind,
	position:    [3]f32,
	direction:   [3]f32, // the way it points
	color:       [3]f32, // colour times intensity
	range:       f32,
	inner_angle: f32,
	outer_angle: f32,
}

Ambient :: struct {
	kind:         Ambient_Kind,
	color:        [4]f32, // 0..1
	ground_color: [4]f32,
}

// Where text lands: queued by render_text, drawn by the render steps.
Queued_Text :: struct {
	text:     string,
	position: [2]f32,
	size:     f32,
	color:    [4]f32,
	space:    Text_Space,
}

FOUR_THIRDS :: f32(4.0 / 3.0)
