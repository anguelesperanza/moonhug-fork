// The PSX world vertex shader: the engine's vertex format and per-instance
// layout (gfx.Vertex, gfx _Instance), but PSX maths in the body.
//
// The engine gives a vertex shader one uniform block (view_proj) and nothing
// else, so the PSX settings it needs ride the instance's model matrix. An
// affine transform's bottom row is always 0 0 0 1, which leaves four floats
// per draw free (psx_render.odin, carrier_matrix):
//   in_model0.w  render width in pixels   (0 = vertex snapping off)
//   in_model1.w  render height in pixels
//   in_model2.w  fog start, world units from the camera
//   in_model3.w  fog end (end <= start = no fog)
//
// Colours stay raw: no sRGB decode (the engine's world shader does it for
// linear lighting; a PS1 blended in gamma space, so this one does too).
#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;
layout(location = 5) in vec4 in_model0;
layout(location = 6) in vec4 in_model1;
layout(location = 7) in vec4 in_model2;
layout(location = 8) in vec4 in_model3;
layout(location = 9) in vec4 in_tint;

layout(set = 1, binding = 0) uniform UBO {
    mat4 view_proj;
    vec4 vert_params;
};

layout(location = 0) out vec2 frag_uv;
layout(location = 1) noperspective out vec2 frag_uv_affine;
layout(location = 2) out vec4 frag_color;
layout(location = 3) out vec3 frag_normal;
layout(location = 4) out float frag_fog; // 1 = no fog, 0 = fully fogged
layout(location = 5) out vec4 frag_tint;

void main() {
    vec2 resolution = vec2(in_model0.w, in_model1.w);
    float fog_start = in_model2.w;
    float fog_end   = in_model3.w;
    mat4 model = mat4(vec4(in_model0.xyz, 0.0), vec4(in_model1.xyz, 0.0), vec4(in_model2.xyz, 0.0), vec4(in_model3.xyz, 1.0));

    vec4 world = model * vec4(in_position, 1.0);
    gl_Position = view_proj * world;

    frag_uv        = in_uv;
    frag_uv_affine = in_uv;
    frag_color     = in_color;
    frag_tint      = in_tint;
    // Inverse transpose, so a non-uniformly scaled object keeps true normals.
    frag_normal    = transpose(inverse(mat3(model))) * in_normal;

    // Worked out per vertex like the PS1's GTE, so the GPU blends it across
    // each triangle and big polygons fog unevenly. For a perspective camera
    // clip w is the distance in front of the camera.
    float depth = gl_Position.w;
    frag_fog = fog_end > fog_start ? clamp((fog_end - depth) / (fog_end - fog_start), 0.0, 1.0) : 1.0;

    // Vertex snapping: positions land on whole pixels of the low-res frame.
    if (resolution.x > 0.0 && gl_Position.w > 0.0) {
        vec2 screen = (gl_Position.xy / gl_Position.w * 0.5 + 0.5) * resolution;
        vec2 ndc = floor(screen + 0.5) / resolution * 2.0 - 1.0;
        gl_Position.xy = ndc * gl_Position.w;
    }
}
