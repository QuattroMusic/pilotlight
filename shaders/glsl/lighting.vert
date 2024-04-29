#version 450
#extension GL_ARB_separate_shader_objects : enable

struct tMaterial
{
    // Metallic Roughness
    int   u_MipCount;
    float u_MetallicFactor;
    float u_RoughnessFactor;
    //-------------------------- ( 16 bytes )

    vec4 u_BaseColorFactor;
    //-------------------------- ( 16 bytes )

    // // Specular Glossiness
    // vec3 u_SpecularFactor;
    // vec4 u_DiffuseFactor;
    // float u_GlossinessFactor;

    // // Sheen
    // float u_SheenRoughnessFactor;
    // vec3 u_SheenColorFactor;

    // Clearcoat
    float u_ClearcoatFactor;
    float u_ClearcoatRoughnessFactor;
    vec2 _unused1;
    //-------------------------- ( 16 bytes )

    // Specular
    vec3 u_KHR_materials_specular_specularColorFactor;
    float u_KHR_materials_specular_specularFactor;
    //-------------------------- ( 16 bytes )

    // // Transmission
    // float u_TransmissionFactor;

    // // Volume
    // float u_ThicknessFactor;
    // vec3 u_AttenuationColor;
    // float u_AttenuationDistance;

    // Iridescence
    float u_IridescenceFactor;
    float u_IridescenceIor;
    float u_IridescenceThicknessMinimum;
    float u_IridescenceThicknessMaximum;
    //-------------------------- ( 16 bytes )

    // Emissive Strength
    vec3 u_EmissiveFactor;
    float u_EmissiveStrength;
    //-------------------------- ( 16 bytes )
    

    // // IOR
    float u_Ior;

    // // Anisotropy
    // vec3 u_Anisotropy;

    // Alpha mode
    float u_AlphaCutoff;
    float u_OcclusionStrength;
    float u_Unuses;
    //-------------------------- ( 16 bytes )

    int BaseColorUVSet;
    int NormalUVSet;
    int EmissiveUVSet;
    int OcclusionUVSet;
    int MetallicRoughnessUVSet;
    int ClearcoatUVSet;
    int ClearcoatRoughnessUVSet;
    int ClearcoatNormalUVSet;
    int SpecularUVSet;
    int SpecularColorUVSet;
    int IridescenceUVSet;
    int IridescenceThicknessUVSet;
};

layout(set = 0, binding = 0) uniform _plGlobalInfo
{
    vec4 tCameraPos;
    mat4 tCameraView;
    mat4 tCameraProjection;
    mat4 tCameraViewProjection;
} tGlobalInfo;

layout(std140, set = 0, binding = 1) readonly buffer _tVertexBuffer
{
	vec4 atVertexData[];
} tVertexBuffer;

layout(set = 0, binding = 2) readonly buffer plMaterialInfo
{
    tMaterial atMaterials[];
} tMaterialInfo;

layout(set = 0, binding = 3)  uniform sampler tDefaultSampler;
layout(set = 0, binding = 4)  uniform sampler tEnvSampler;
layout (set = 0, binding = 5) uniform textureCube u_LambertianEnvSampler;
layout (set = 0, binding = 6) uniform textureCube u_GGXEnvSampler;
layout (set = 0, binding = 7) uniform texture2D u_GGXLUT;

layout(set = 2, binding = 0)  uniform texture2D tSkinningSampler;

layout(set = 3, binding = 0) uniform _plObjectInfo
{
    int iDataOffset;
    int iVertexOffset;
} tObjectInfo;

// input
layout(location = 0) in vec3 inPos;

// output
layout(location = 0) out struct plShaderOut {
    vec2 tUV;
} tShaderOut;

void main() 
{

    vec4 inPosition  = vec4(inPos, 1.0);
    vec2 inTexCoord0 = vec2(0.0, 0.0);
    int iCurrentAttribute = 0;

    const uint iVertexDataOffset = 1 * (gl_VertexIndex - tObjectInfo.iVertexOffset) + tObjectInfo.iDataOffset;
    inTexCoord0 = tVertexBuffer.atVertexData[iVertexDataOffset + iCurrentAttribute].xy;  iCurrentAttribute++;
    gl_Position = inPosition;
    tShaderOut.tUV = inTexCoord0;
}