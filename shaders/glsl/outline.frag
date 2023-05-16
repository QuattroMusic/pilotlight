#version 450
#extension GL_ARB_separate_shader_objects : enable

#include "common.glsl"

// output
layout(location = 0) out vec4 outColor;

void main() 
{
    outColor = tMaterialBuffer.atMaterialData[tObjectInfo.uMaterialIndex].tAlbedo;
}