// Semi-transparency: the PS1's four blend modes between the frame behind (B)
// and an object drawn into its own layer (F). `layer` holds F with its
// coverage in alpha; where the layer is empty the frame passes through.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D frame;
layout(set = 2, binding = 1) uniform sampler2D layer;

layout(set = 3, binding = 1) uniform CompositeUBO {
    vec4 params; // x mode: 1 half (0.5B + 0.5F), 2 add (B + F), 3 subtract (B - F), 4 quarter add (B + 0.25F)
};

void main() {
    ivec2 size = textureSize(frame, 0);
    ivec2 p = min(ivec2(frag_uv * vec2(size)), size - 1);
    vec3 b = texelFetch(frame, p, 0).rgb;
    vec4 f = texelFetch(layer, p, 0);
    vec3 result = b;
    if (f.a > 0.5) {
        int mode = int(params.x + 0.5);
        if (mode == 1)      result = b * 0.5 + f.rgb * 0.5;
        else if (mode == 2) result = b + f.rgb;
        else if (mode == 3) result = b - f.rgb;
        else if (mode == 4) result = b + f.rgb * 0.25;
        else                result = f.rgb;
    }
    out_color = vec4(clamp(result, 0.0, 1.0), 1.0);
}
