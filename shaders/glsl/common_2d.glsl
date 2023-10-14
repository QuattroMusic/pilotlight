
//-----------------------------------------------------------------------------
// [SECTION] forward declarations
//-----------------------------------------------------------------------------

const int PL_MESH_FORMAT_FLAG_NONE           = 0;
const int PL_MESH_FORMAT_FLAG_HAS_POSITION   = 1 << 0;
const int PL_MESH_FORMAT_FLAG_HAS_NORMAL     = 1 << 1;
const int PL_MESH_FORMAT_FLAG_HAS_TANGENT    = 1 << 2;
const int PL_MESH_FORMAT_FLAG_HAS_TEXCOORD_0 = 1 << 3;
const int PL_MESH_FORMAT_FLAG_HAS_TEXCOORD_1 = 1 << 4;
const int PL_MESH_FORMAT_FLAG_HAS_COLOR_0    = 1 << 5;
const int PL_MESH_FORMAT_FLAG_HAS_COLOR_1    = 1 << 6;
const int PL_MESH_FORMAT_FLAG_HAS_JOINTS_0   = 1 << 7;
const int PL_MESH_FORMAT_FLAG_HAS_JOINTS_1   = 1 << 8;
const int PL_MESH_FORMAT_FLAG_HAS_WEIGHTS_0  = 1 << 9;
const int PL_MESH_FORMAT_FLAG_HAS_WEIGHTS_1  = 1 << 10;

const int PL_TEXTURE_HAS_BASE_COLOR   = 1 << 0;
const int PL_TEXTURE_HAS_NORMAL       = 1 << 1;

layout(constant_id = 0) const int MeshVariantFlags = PL_MESH_FORMAT_FLAG_NONE;
layout(constant_id = 1) const int PL_DATA_STRIDE = 0;
layout(constant_id = 2) const int ShaderTextureFlags = 0;

//-----------------------------------------------------------------------------
// [SECTION] global
//-----------------------------------------------------------------------------

layout(set = 0, binding = 0) uniform _plGlobalInfo
{
    int iViewportWidth;
    int iViewportHeight;
} tGlobalInfo;

layout(std140, set = 0, binding = 1) readonly buffer _tVertexBuffer
{
	vec4 atVertexData[];
} tVertexBuffer;

layout(set = 1, binding = 0) uniform sampler2D tSampler0;

layout(set = 2, binding = 0) uniform _plShaderInfo
{
    vec4 shaderSpecific;
} tShaderInfo;

layout(set = 3, binding = 0) uniform _plObjectInfo
{
    int  iDataOffset;
    int  iVertexOffset;
    vec2 tOffset;
} tObjectInfo;