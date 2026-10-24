#!/bin/sh
# Compiles this plugin's shaders to the committed blobs in compiled/: SPIR-V
# with glslc, Metal source with spirv-cross, the same way `mh shaders` does for
# the engine's. Needs glslc and spirv-cross on PATH (the Vulkan SDK, or
# `brew install shaderc spirv-cross`). Compiled output is committed, so this is
# only needed to CHANGE a shader.
set -e
cd "$(dirname "$0")"
mkdir -p compiled
for src in psx.vert psx.frag psx_interlace.frag psx_composite.frag psx_present.frag; do
    stage=${src##*.}
    glslc -fshader-stage=$stage "$src.glsl" -o "compiled/$src.spv"
    if [ "$stage" = "vert" ]; then
        spirv-cross --msl --msl-decoration-binding --msl-version 20100 "compiled/$src.spv" --output "compiled/$src.msl"
    else
        spirv-cross --msl --msl-decoration-binding "compiled/$src.spv" --output "compiled/$src.msl"
    fi
    echo "compiled $src"
done
