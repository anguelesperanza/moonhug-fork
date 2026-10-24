// The PSX world fragment shader: nearest texel fetch with repeat, affine or
// perspective texture coordinates, baked or live vertex lighting, colour-key
// transparency, fog, and the 15-bit colour cut with the PS1's 4x4 dither.
//
// SDL_GPU SPIR-V convention: fragment samplers in set 2, uniform buffers in
// set 3. The engine pushes its own blocks at slots 0 and 2 for every mesh
// draw; this shader reads only slot 1, the per-draw block gfx.draw_mesh's
// `material` bytes fill.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) noperspective in vec2 frag_uv_affine;
layout(location = 2) in vec4 frag_color;
layout(location = 3) in vec3 frag_normal;
layout(location = 4) in float frag_fog;
layout(location = 5) in vec4 frag_tint;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform PsxUBO {
    vec4 fog_color;      // rgb: what fogged geometry fades into
    vec4 flags;          // x affine textures, y 15-bit colour, z dithering, w colour key
    vec4 lighting;       // x mode (0 unlit, 1 baked, 2 live), y hemisphere ambient, z max light
    vec4 ambient;        // rgb
    vec4 ambient_ground; // rgb
    vec4 live_dir[3];    // xyz: toward the light
    vec4 live_col[3];    // rgb: what reaches the object
};

layout(location = 0) out vec4 out_color;

const float dither_table[16] = float[16](
    -4.0,  0.0, -3.0,  1.0,
     2.0, -2.0,  3.0, -1.0,
    -3.0,  1.0, -4.0,  0.0,
     3.0, -1.0,  2.0, -2.0
);

void main() {
    vec2 uv = flags.x > 0.5 ? frag_uv_affine : frag_uv;

    // Nearest filtering, no mip levels, repeating: what the PS1 sampled.
    ivec2 size = textureSize(tex, 0);
    ivec2 texel_pos = min(ivec2(floor(fract(uv) * vec2(size))), size - 1);
    vec4 texel = texelFetch(tex, texel_pos, 0);

    if (flags.w > 0.5) {
        if (texel.a < 0.5 || texel.rgb == vec3(0.0)) discard;
        texel.a = 1.0;
    }

    vec3 lit = vec3(1.0);
    float lit_alpha = 1.0;
    if (lighting.x > 0.5) {
        vec3 n = normalize(frag_normal);
        vec3 light = ambient.rgb;
        if (lighting.y > 0.5) light = mix(ambient_ground.rgb, ambient.rgb, n.y * 0.5 + 0.5);
        if (lighting.x < 1.5) {
            // Baked: the vertex colour holds the lights at half strength.
            lit = min(frag_color.rgb * 2.0 + light, vec3(lighting.z));
        } else {
            for (int i = 0; i < 3; i++) {
                light += live_col[i].rgb * max(dot(n, live_dir[i].xyz), 0.0);
            }
            lit = min(light, vec3(lighting.z)) * frag_color.rgb;
        }
        lit_alpha = frag_color.a;
    }

    vec4 color = texel * frag_tint * vec4(lit, lit_alpha);
    // Only colour fades to fog; alpha is left alone so cutouts stay cut out.
    vec3 rgb = mix(fog_color.rgb, color.rgb, frag_fog);

    if (flags.y > 0.5) {
        vec3 c = floor(clamp(rgb, 0.0, 1.0) * 255.0 + 0.5);
        if (flags.z > 0.5) {
            // gl_FragCoord is top-down here and bottom-up in OpenGL, which the
            // original tuned the table for: flip rows so the pattern matches.
            ivec2 p = ivec2(gl_FragCoord.xy);
            p = ivec2(p.x & 3, 3 - (p.y & 3));
            c += dither_table[p.y * 4 + p.x];
        }
        c = floor(clamp(c, 0.0, 255.0) / 8.0);
        rgb = c / 31.0;
    }

    out_color = vec4(clamp(rgb, 0.0, 1.0), color.a);
}
