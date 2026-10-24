// Puts the low-res frame on the window: the display rectangle (4:3 bars or the
// whole window), nearest sampling, and the CRT effects of the original post
// pass (composite blur, scanlines, curvature, aperture-grille mask, vignette).
// Output is the colour the window should show, converted to linear because the
// engine encodes a Display pass back to sRGB when it ends.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform PresentUBO {
    vec4 rect;   // display rectangle in window pixels: x, y, width, height
    vec4 source; // x, y: frame size in pixels
    vec4 effect; // x blur, y scanlines, z curvature, w vignette
    vec4 extra;  // x mask, y overscan, z effects on
};

const mat3 toYIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
const mat3 toRGB = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);

vec3 fetch(vec2 uv) {
    ivec2 size = ivec2(source.xy);
    return texelFetch(tex, clamp(ivec2(floor(uv * source.xy)), ivec2(0), size - 1), 0).rgb;
}

vec3 composite(vec2 uv) {
    vec3 c = fetch(uv);
    float blur = effect.x;
    if (blur <= 0.0) return c;

    vec2 dx = vec2(1.0 / source.x, 0.0);
    vec3 l1 = fetch(uv - dx);
    vec3 r1 = fetch(uv + dx);
    vec3 l2 = fetch(uv - dx * 2.0);
    vec3 r2 = fetch(uv + dx * 2.0);

    vec3 sharp = toYIQ * c;
    vec3 near  = toYIQ * (c * 0.5 + (l1 + r1) * 0.25);
    vec3 wide  = toYIQ * ((c + l1 + r1 + l2 + r2) / 5.0);

    vec3 yiq = vec3(mix(sharp.x, near.x, blur), mix(sharp.yz, wide.yz, blur));
    return clamp(toRGB * yiq, 0.0, 1.0);
}

vec3 to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    vec2 pixel = gl_FragCoord.xy;
    vec2 uv = (pixel - rect.xy) / rect.zw;
    if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) {
        out_color = vec4(0.0, 0.0, 0.0, 1.0); // the bars
        return;
    }

    vec3 color;
    if (extra.z < 0.5) {
        color = fetch(uv);
    } else {
        float curvature = effect.z;
        if (curvature > 0.0) {
            vec2 centred = uv * 2.0 - 1.0;
            if (extra.y > 0.5) {
                float zoom = 1.0 / (1.0 + 2.0 * curvature);
                for (int i = 0; i < 3; i++) {
                    zoom -= (2.0 * curvature * zoom * zoom * zoom + zoom - 1.0) / (6.0 * curvature * zoom * zoom + 1.0);
                }
                centred *= zoom;
            }
            centred *= 1.0 + curvature * dot(centred, centred);
            uv = centred * 0.5 + 0.5;
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
                out_color = vec4(0.0, 0.0, 0.0, 1.0);
                return;
            }
        }

        color = composite(uv);

        float scanlines = effect.y;
        if (scanlines > 0.0) {
            float row = fract(uv.y * source.y);
            color *= mix(1.0, 0.25 + 0.75 * sin(row * 3.14159265), scanlines) * (1.0 + 0.25 * scanlines);
        }

        float mask = extra.x;
        if (mask > 0.0) {
            int column = int(gl_FragCoord.x) % 3;
            float dim = 1.0 - 0.35 * mask;
            vec3 stripe = column == 0 ? vec3(1.0, dim, dim) : column == 1 ? vec3(dim, 1.0, dim) : vec3(dim, dim, 1.0);
            color *= stripe;
        }

        float vignette = effect.w;
        if (vignette > 0.0) {
            vec2 centred = uv * 2.0 - 1.0;
            color *= clamp(1.0 - dot(centred, centred) * 0.5 * vignette, 0.0, 1.0);
        }
    }

    out_color = vec4(to_linear(clamp(color, 0.0, 1.0)), 1.0);
}
