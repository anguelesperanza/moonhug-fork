// Interlacing: each frame redraws only the lines of one field, so the lines of
// the other keep the previous frame and moving edges comb. `field` -1 draws
// every line (the first frame, or after the target was recreated).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform InterlaceUBO {
    vec4 params; // x field (-1, 0, 1)
};

void main() {
    int field = int(params.x + (params.x < 0.0 ? -0.5 : 0.5));
    if (field >= 0 && (int(gl_FragCoord.y) & 1) != field) discard;
    ivec2 size = textureSize(tex, 0);
    out_color = texelFetch(tex, min(ivec2(frag_uv * vec2(size)), size - 1), 0);
}
