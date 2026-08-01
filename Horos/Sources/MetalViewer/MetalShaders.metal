#include <metal_stdlib>
using namespace metal;

constant uint kRegistrationHistogramBins = 64;
constant uint kMetalViewerInterpolationNearest = 0;
constant uint kMetalViewerInterpolationLanczos = 2;

struct MetalVertex {
    float2 position;
    float2 texCoord;
};

struct MetalUniforms {
    float2 scale;
    float2 offset;
    float rotationRadians;
    float drawableAspect;
    float baseWindowLevel;
    float baseWindowWidth;
    float overlayWindowLevel;
    float overlayWindowWidth;
    float overlayBlend;
    float3 overlayTranslationWorld;
    float3 movingRotationCenterWorld;
    uint3 fixedVolumeSize;
    float currentSliceIndex;
    float4x4 movingInverseRotation;
    float4x4 fixedVoxelToWorld;
    float4x4 movingWorldToVoxel;
    uint hasOverlay;
    uint imageInterpolationMode;
    uint baseHasCustomCLUT;
    uint overlayHasCustomCLUT;
    uint baseVolumeTextureKind;
    float baseVolumeRescaleSlope;
    float baseVolumeRescaleIntercept;
    uint baseVolumePadding;
};

struct MetalMPRVertex {
    float3 position;
    float3 baseVoxel;
    float4 color;
};

struct MetalMPRUniforms {
    float4x4 viewProjectionMatrix;
    float baseWindowLevel;
    float baseWindowWidth;
    float overlayWindowLevel;
    float overlayWindowWidth;
    float overlayBlend;
    float3 overlayTranslationWorld;
    float3 movingRotationCenterWorld;
    uint3 fixedVolumeSize;
    float4x4 movingInverseRotation;
    float4x4 fixedVoxelToWorld;
    float4x4 movingWorldToVoxel;
    uint hasOverlay;
    uint baseHasCustomCLUT;
    uint overlayHasCustomCLUT;
};

struct MetalPreviewUniforms {
    float2 scale;
    float2 offset;
    float windowLevel;
    float windowWidth;
    float currentSliceIndex;
    uint useVolumeTexture;
    uint volumeTextureKind;
    float rescaleSlope;
    float rescaleIntercept;
    float padding;
};

struct RegistrationUniforms {
    float baseWindowLevel;
    float baseWindowWidth;
    float overlayWindowLevel;
    float overlayWindowWidth;
    float4 metricOptions;
    float3 overlayTranslationWorld;
    float3 movingRotationCenterWorld;
    uint3 baseTextureSize;
    float4x4 movingInverseRotation;
    float4x4 fixedVoxelToWorld;
    float4x4 movingWorldToVoxel;
};

struct GaussianBlurUniforms {
    uint3 sourceSize;
    uint axis;
    uint radius;
};

struct DownsampleUniforms {
    uint3 sourceSize;
    uint factor;
};

struct GantryTiltResampleUniforms {
    uint4 outputSize;
    float4x4 outputVoxelToWorld;
    float4x4 sourceWorldToVoxel;
    float4 backgroundValue;
};

struct StoredVolumeConversionUniforms {
    uint4 sourceSize;
    float4 rescale;
};

struct Metal3DHistogramUniforms {
    uint4 sourceSize;
    float2 domain;
    uint binCount;
    uint padding;
};

struct RasterizerData {
    float4 position [[position]];
    float2 texCoord;
};

struct MetalMPRRasterizerData {
    float4 position [[position]];
    float3 baseVoxel;
    float4 color;
};

struct MetalMPRBorderRasterizerData {
    float4 position [[position]];
    float4 color;
};

struct Metal3DVertex {
    float2 position;
    float2 uv;
};

struct Metal3DVolumeUniforms {
    float3 cameraPosition;
    float tanHalfFovY;
    float3 cameraRight;
    float aspectRatio;
    float3 cameraUp;
    float stepSize;
    float3 cameraForward;
    float density;
    float alphaFloor;
    float3 boxMin;
    float padding0;
    float3 boxMax;
    float padding1;
    float3 cropBoxMin;
    float padding2;
    float3 cropBoxMax;
    float padding3;
    uint3 volumeDimensions;
    uint cropEnabled;
    float3 voxelSpacing;
    uint maxSteps;
    float windowLevel;
    float windowWidth;
    float4 boneRenderingOptions;
    float opacityDomainMin;
    float opacityDomainMax;
    uint useRawOpacityCurve;
    uint usePreIntegratedTransfer;
    float shading;
    float ambient;
    float diffuse;
    float specular;
    float specularPower;
    uint hasCLUT;
    uint skinMaskEnabled;
    float4x4 viewProjectionMatrix;
};

struct Metal3DRasterizerData {
    float4 position [[position]];
    float2 uv;
};

struct Metal3DSurfaceExtractionUniforms {
    uint width;
    uint height;
    uint depth;
    uint voxelCount;
    uint cellWidth;
    uint cellHeight;
    uint cellDepth;
    uint cellCount;
    float spacingX;
    float spacingY;
    float spacingZ;
    float threshold;
};

static inline bool metal3DSurfaceVoxelInside(device const float *volume,
                                             constant Metal3DSurfaceExtractionUniforms &uniforms,
                                             int x,
                                             int y,
                                             int z)
{
    if (x < 0 || y < 0 || z < 0 ||
        x >= int(uniforms.width) ||
        y >= int(uniforms.height) ||
        z >= int(uniforms.depth)) {
        return false;
    }

    const uint index = uint(z) * uniforms.width * uniforms.height + uint(y) * uniforms.width + uint(x);
    return index < uniforms.voxelCount && volume[index] >= uniforms.threshold;
}

static inline void metal3DStoreSurfaceVertex(device float *vertices,
                                             uint vertexIndex,
                                             float3 position,
                                             float3 normal)
{
    const uint base = vertexIndex * 6;
    vertices[base + 0] = position.x;
    vertices[base + 1] = position.y;
    vertices[base + 2] = position.z;
    vertices[base + 3] = normal.x;
    vertices[base + 4] = normal.y;
    vertices[base + 5] = normal.z;
}

kernel void metal3DCountSurfaceFaces(device const float *volume [[buffer(0)]],
                                     device uint *faceCounts [[buffer(1)]],
                                     device uchar *surfaceMask [[buffer(2)]],
                                     constant Metal3DSurfaceExtractionUniforms &uniforms [[buffer(3)]],
                                     uint index [[thread_position_in_grid]])
{
    if (index >= uniforms.voxelCount) {
        return;
    }

    const uint slice = uniforms.width * uniforms.height;
    const uint z = index / slice;
    const uint remainder = index - z * slice;
    const uint y = remainder / uniforms.width;
    const uint x = remainder - y * uniforms.width;

    uint faceCount = 0;
    if (metal3DSurfaceVoxelInside(volume, uniforms, int(x), int(y), int(z))) {
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x) - 1, int(y), int(z)) ? 0 : 1;
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x) + 1, int(y), int(z)) ? 0 : 1;
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x), int(y) - 1, int(z)) ? 0 : 1;
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x), int(y) + 1, int(z)) ? 0 : 1;
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x), int(y), int(z) - 1) ? 0 : 1;
        faceCount += metal3DSurfaceVoxelInside(volume, uniforms, int(x), int(y), int(z) + 1) ? 0 : 1;
    }

    faceCounts[index] = faceCount;
    surfaceMask[index] = faceCount == 0 ? 0 : 255;
}

struct Metal3DSurfaceNetVertex {
    float3 position;
    float3 normal;
    float value;
};

constant uchar kMetal3DMarchingCubesEdgeCorners[24] = {
    0, 1, 1, 2, 3, 2, 0, 3,
    4, 5, 5, 6, 7, 6, 4, 7,
    0, 4, 1, 5, 3, 7, 2, 6
};

// Each case stores 16 four-bit edge ids; 0xf is the triangle-list sentinel.
constant uint kMetal3DMarchingCubesTriangles[512] = {
    0xffffffffu, 0xffffffffu, 0xfffff830u, 0xffffffffu,
    0xfffff190u, 0xffffffffu, 0xff819831u, 0xffffffffu,
    0xfffff2b1u, 0xffffffffu, 0xff2b1830u, 0xffffffffu,
    0xff2902b9u, 0xffffffffu, 0x8bb82832u, 0xfffffff9u,
    0xfffffa23u, 0xffffffffu, 0xffa08a20u, 0xffffffffu,
    0xff3a2901u, 0xffffffffu, 0xa99a1a21u, 0xfffffff8u,
    0xffb3ab13u, 0xffffffffu, 0xb88b0b10u, 0xfffffffau,
    0x9aa93903u, 0xfffffffbu, 0xff8ab8b9u, 0xffffffffu,
    0xfffff784u, 0xffffffffu, 0xff347304u, 0xffffffffu,
    0xff478190u, 0xffffffffu, 0x17714194u, 0xfffffff3u,
    0xff4782b1u, 0xffffffffu, 0xb1043473u, 0xfffffff2u,
    0x780292b9u, 0xfffffff4u, 0x32972b92u, 0xffff9477u,
    0xffa23478u, 0xffffffffu, 0x4224a47au, 0xfffffff0u,
    0xa2478019u, 0xfffffff3u, 0x294a97a4u, 0xffff219au,
    0x47ab3b13u, 0xfffffff8u, 0x414a1ab1u, 0xffffa470u,
    0xb90a9784u, 0xffff03aau, 0xb9a947a4u, 0xfffffffau,
    0xfffff549u, 0xffffffffu, 0xff830549u, 0xffffffffu,
    0xff501540u, 0xffffffffu, 0x53358548u, 0xfffffff1u,
    0xff5492b1u, 0xffffffffu, 0x542b1083u, 0xfffffff9u,
    0x244252b5u, 0xfffffff0u, 0x43253b52u, 0xffff4835u,
    0xff3a2549u, 0xffffffffu, 0x548a0a20u, 0xfffffff9u,
    0xa2150540u, 0xfffffff3u, 0xa2582152u, 0xffff8548u,
    0x4913b3abu, 0xfffffff5u, 0x18810954u, 0xffffab8bu,
    0xb50a5405u, 0xffff03aau, 0xab8b5485u, 0xfffffff8u,
    0xff795789u, 0xffffffffu, 0x35539309u, 0xfffffff7u,
    0x71170780u, 0xfffffff5u, 0xff573531u, 0xffffffffu,
    0x2b579789u, 0xfffffff1u, 0x0550912bu, 0xffff7353u,
    0x78258028u, 0xffff52b5u, 0x73532b52u, 0xfffffff5u,
    0x23897957u, 0xfffffffau, 0x09729579u, 0xffff7a22u,
    0x811803a2u, 0xffff5717u, 0x5717a21au, 0xfffffff1u,
    0x3b578589u, 0xffff3ab1u, 0x07095705u, 0xfb0a0b1au,
    0x0b03ab0au, 0xf7050785u, 0xffa57b5au, 0xffffffffu,
    0xfffff65bu, 0xffffffffu, 0xffb65830u, 0xffffffffu,
    0xffb65019u, 0xffffffffu, 0x65981831u, 0xfffffffbu,
    0xff612651u, 0xffffffffu, 0x83261651u, 0xfffffff0u,
    0x60069659u, 0xfffffff2u, 0x65825985u, 0xffff2832u,
    0xff65b3a2u, 0xffffffffu, 0x5b20a08au, 0xfffffff6u,
    0x653a2190u, 0xfffffffbu, 0x29921b65u, 0xffff8a9au,
    0x355363a6u, 0xfffffff1u, 0x10a508a0u, 0xffffa655u,
    0x50360a63u, 0xffff5906u, 0x8a9a6596u, 0xfffffff9u,
    0xff784b65u, 0xffffffffu, 0xb6734304u, 0xfffffff5u,
    0x78b65901u, 0xfffffff4u, 0x3197165bu, 0xffff9477u,
    0x84516126u, 0xfffffff7u, 0x43265251u, 0xffff4730u,
    0x50059478u, 0xffff2606u, 0x93947397u, 0xf6929652u,
    0x5b847a23u, 0xfffffff6u, 0x04724b65u, 0xffff7a22u,
    0xa2784190u, 0xffffb653u, 0xa9a29219u, 0xfb65a474u,
    0x13a53478u, 0xffffa655u, 0xa1a651a5u, 0xf4a0a470u,
    0x60650590u, 0xf47863a3u, 0x949a6596u, 0xffffa977u,
    0xff4b649bu, 0xffffffffu, 0x309b4b64u, 0xfffffff8u,
    0x0660b01bu, 0xfffffff4u, 0x48168318u, 0xffff1b66u,
    0x42241491u, 0xfffffff6u, 0x92291083u, 0xffff6424u,
    0xff264240u, 0xffffffffu, 0x64248328u, 0xfffffff2u,
    0x3a64b49bu, 0xfffffff2u, 0xb48a2820u, 0xffffb649u,
    0x40160a23u, 0xffff1b66u, 0x141b6416u, 0xfa181a28u,
    0x39369649u, 0xffff63a1u, 0x1a108a18u, 0xf4161496u,
    0x40603a63u, 0xfffffff6u, 0xff68a486u, 0xffffffffu,
    0xb88b7b67u, 0xfffffff9u, 0xb0b70730u, 0xffff7b69u,
    0x81b7167bu, 0xffff8017u, 0x3171b67bu, 0xfffffff7u,
    0x91681261u, 0xffff6788u, 0x96912692u, 0xf3979307u,
    0x26067807u, 0xfffffff0u, 0xff726327u, 0xffffffffu,
    0x9b68b3a2u, 0xffff6788u, 0x707a2072u, 0xfb797b69u,
    0x71781801u, 0xf3a27b6bu, 0x1b17a21au, 0xffff7166u,
    0x69678968u, 0xf36163a1u, 0xff67a910u, 0xffffffffu,
    0x03067807u, 0xffff60aau, 0xfffffa67u, 0xffffffffu,
    0xfffff6a7u, 0xffffffffu, 0xff76a083u, 0xffffffffu,
    0xff76a190u, 0xffffffffu, 0x6a318198u, 0xfffffff7u,
    0xffa7612bu, 0xffffffffu, 0x760832b1u, 0xfffffffau,
    0x76b92902u, 0xfffffffau, 0x3bb32a76u, 0xffff98b8u,
    0xff276237u, 0xffffffffu, 0x06607087u, 0xfffffff2u,
    0x90372762u, 0xfffffff1u, 0x81861621u, 0xffff7689u,
    0x7117b76bu, 0xfffffff3u, 0x717b176bu, 0xffff0818u,
    0x907b0370u, 0xffffb76bu, 0x98b876b7u, 0xfffffffbu,
    0xff86a846u, 0xffffffffu, 0x600636a3u, 0xfffffff4u,
    0x194686a8u, 0xfffffff0u, 0x19639469u, 0xffff36a3u,
    0x12a86846u, 0xfffffffbu, 0xa00a32b1u, 0xffff4606u,
    0x906a4a84u, 0xffffb922u, 0x3932b93bu, 0xf63436a4u,
    0x24428238u, 0xfffffff6u, 0xff624420u, 0xffffffffu,
    0x62342901u, 0xffff3844u, 0x62421941u, 0xfffffff4u,
    0x68618138u, 0xffffb164u, 0x4606b10bu, 0xfffffff0u,
    0x36384634u, 0xf93b390bu, 0xffb4694bu, 0xffffffffu,
    0xff6a7954u, 0xffffffffu, 0x6a954830u, 0xfffffff7u,
    0xa7405015u, 0xfffffff6u, 0x4334876au, 0xffff1535u,
    0xa712b549u, 0xfffffff6u, 0x302b1a76u, 0xffff9548u,
    0xb44b56a7u, 0xffff0242u, 0x53543483u, 0xf76a52b2u,
    0x95627237u, 0xfffffff4u, 0x20860549u, 0xffff8766u,
    0x01763623u, 0xffff4055u, 0x82876286u, 0xf5818541u,
    0x6116b549u, 0xffff3717u, 0x717616b1u, 0xf5497080u,
    0xb0b540b4u, 0xf7b3b763u, 0xb5b876b7u, 0xffff8b44u,
    0x9aa96956u, 0xfffffff8u, 0x606306a3u, 0xffff9505u,
    0x505a0a80u, 0xffff6a51u, 0x15356a36u, 0xfffffff3u,
    0x895a92b1u, 0xffff56aau, 0x606a0a30u, 0xf2b16959u,
    0x5856a85au, 0xf25052b0u, 0x32356a36u, 0xffff53bbu,
    0x25285895u, 0xffff8236u, 0x20609569u, 0xfffffff6u,
    0x85801581u, 0xf2868236u, 0xff162561u, 0xffffffffu,
    0x636b1361u, 0xf9686958u, 0x0906b10bu, 0xffff6055u,
    0xff6b5380u, 0xffffffffu, 0xfffff56bu, 0xffffffffu,
    0xff5a75bau, 0xffffffffu, 0x0875a5bau, 0xfffffff3u,
    0x01ba5a75u, 0xfffffff9u, 0x19a7b75bu, 0xffff3188u,
    0x1771a12au, 0xfffffff5u, 0x51271830u, 0xffff2a77u,
    0x29279759u, 0xffffa720u, 0x252a7527u, 0xf8292839u,
    0x533525b2u, 0xfffffff7u, 0x58528208u, 0xffff25b7u,
    0x75b35019u, 0xffffb233u, 0x28219829u, 0xf52725b7u,
    0xff753351u, 0xffffffffu, 0x51710870u, 0xfffffff7u,
    0x75359039u, 0xfffffff3u, 0xff975879u, 0xffffffffu,
    0x8bb85845u, 0xfffffffau, 0xa5a05045u, 0xffff30abu,
    0xa84b8190u, 0xffff45bbu, 0x4a45ba4bu, 0xf1434193u,
    0x82852512u, 0xffff584au, 0xa4a304a0u, 0xf1a5a125u,
    0x52590250u, 0xf85a584au, 0xffa32459u, 0xffffffffu,
    0x535235b2u, 0xffff8434u, 0x04245b25u, 0xfffffff2u,
    0x535b3b23u, 0xf1905848u, 0x21245b25u, 0xffff4299u,
    0x13538458u, 0xfffffff5u, 0xff051450u, 0xffffffffu,
    0x59538458u, 0xffff3500u, 0xfffff459u, 0xffffffffu,
    0xa99a4a74u, 0xfffffffbu, 0x79974830u, 0xffffba9au,
    0x01a41ba1u, 0xffff4a74u, 0x41483143u, 0xfa4b4a7bu,
    0xa9a49a74u, 0xffff1292u, 0xa9a79749u, 0xf830a121u,
    0x0242a74au, 0xfffffff4u, 0x4842a74au, 0xffff2433u,
    0x727929b2u, 0xffff4973u, 0x7b749b79u, 0xf0727082u,
    0xb7b237b3u, 0xf0b4b014u, 0xff748b21u, 0xffffffffu,
    0x37174914u, 0xfffffff1u, 0x10174914u, 0xffff7188u,
    0xff437034u, 0xffffffffu, 0xfffff874u, 0xffffffffu,
    0xffa8bb89u, 0xffffffffu, 0xba9a3093u, 0xfffffff9u,
    0xa8b801b0u, 0xfffffffbu, 0xff3ba1b3u, 0xffffffffu,
    0x89a912a1u, 0xfffffffau, 0x919a3093u, 0xffffa922u,
    0xff0a82a0u, 0xffffffffu, 0xfffff2a3u, 0xffffffffu,
    0x9b8b2382u, 0xfffffff8u, 0xff920b29u, 0xffffffffu,
    0x808b2382u, 0xffffb811u, 0xfffffb21u, 0xffffffffu,
    0xff189381u, 0xffffffffu, 0xfffff910u, 0xffffffffu,
    0xfffff380u, 0xffffffffu, 0xffffffffu, 0xffffffffu,
};

static inline uint metal3DCubeVertexX(uint index)
{
    return (index == 1 || index == 2 || index == 5 || index == 6) ? 1 : 0;
}

static inline uint metal3DCubeVertexY(uint index)
{
    return (index == 2 || index == 3 || index == 6 || index == 7) ? 1 : 0;
}

static inline uint metal3DCubeVertexZ(uint index)
{
    return index >= 4 ? 1 : 0;
}

static inline float metal3DSurfaceGridValue(device const float *volume,
                                            constant Metal3DSurfaceExtractionUniforms &uniforms,
                                            int x,
                                            int y,
                                            int z)
{
    if (x < 0 || y < 0 || z < 0 ||
        x >= int(uniforms.width) ||
        y >= int(uniforms.height) ||
        z >= int(uniforms.depth)) {
        return 0.0f;
    }

    const uint index = uint(z) * uniforms.width * uniforms.height + uint(y) * uniforms.width + uint(x);
    return index < uniforms.voxelCount ? volume[index] : 0.0f;
}

static inline float3 metal3DSurfaceGridNormal(device const float *volume,
                                              constant Metal3DSurfaceExtractionUniforms &uniforms,
                                              int x,
                                              int y,
                                              int z)
{
    const float invSpacingX = 1.0f / max(uniforms.spacingX, 0.0001f);
    const float invSpacingY = 1.0f / max(uniforms.spacingY, 0.0001f);
    const float invSpacingZ = 1.0f / max(uniforms.spacingZ, 0.0001f);
    const float gx = (metal3DSurfaceGridValue(volume, uniforms, x + 1, y, z) -
                      metal3DSurfaceGridValue(volume, uniforms, x - 1, y, z)) * invSpacingX;
    const float gy = (metal3DSurfaceGridValue(volume, uniforms, x, y + 1, z) -
                      metal3DSurfaceGridValue(volume, uniforms, x, y - 1, z)) * invSpacingY;
    const float gz = (metal3DSurfaceGridValue(volume, uniforms, x, y, z + 1) -
                      metal3DSurfaceGridValue(volume, uniforms, x, y, z - 1)) * invSpacingZ;
    const float3 outward = -float3(gx, gy, gz);
    return length_squared(outward) > 0.000001f ? normalize(outward) : float3(0.0f, 0.0f, 1.0f);
}

static inline Metal3DSurfaceNetVertex metal3DSurfaceCubeVertex(device const float *volume,
                                                               constant Metal3DSurfaceExtractionUniforms &uniforms,
                                                               uint cellX,
                                                               uint cellY,
                                                               uint cellZ,
                                                               uint cubeVertexIndex)
{
    const uint gx = cellX + metal3DCubeVertexX(cubeVertexIndex);
    const uint gy = cellY + metal3DCubeVertexY(cubeVertexIndex);
    const uint gz = cellZ + metal3DCubeVertexZ(cubeVertexIndex);
    Metal3DSurfaceNetVertex surfaceVertex;
    surfaceVertex.position = float3(
        (float(gx) - 1.0f) * uniforms.spacingX,
        (float(gy) - 1.0f) * uniforms.spacingY,
        (float(gz) - 1.0f) * uniforms.spacingZ
    );
    surfaceVertex.normal = metal3DSurfaceGridNormal(volume, uniforms, int(gx), int(gy), int(gz));
    surfaceVertex.value = metal3DSurfaceGridValue(volume, uniforms, int(gx), int(gy), int(gz));
    return surfaceVertex;
}

static inline Metal3DSurfaceNetVertex metal3DInterpolateSurfaceVertex(Metal3DSurfaceNetVertex a,
                                                                      Metal3DSurfaceNetVertex b,
                                                                      float threshold)
{
    const float denominator = b.value - a.value;
    const float t = abs(denominator) > 0.000001f ? clamp((threshold - a.value) / denominator, 0.0f, 1.0f) : 0.5f;
    Metal3DSurfaceNetVertex surfaceVertex;
    surfaceVertex.position = mix(a.position, b.position, t);
    const float3 normal = mix(a.normal, b.normal, t);
    surfaceVertex.normal = length_squared(normal) > 0.000001f ? normalize(normal) : float3(0.0f, 0.0f, 1.0f);
    surfaceVertex.value = threshold;
    return surfaceVertex;
}

static inline void metal3DStoreSurfaceNetVertex(device float *vertices,
                                                uint vertexIndex,
                                                Metal3DSurfaceNetVertex surfaceVertex)
{
    metal3DStoreSurfaceVertex(vertices, vertexIndex, surfaceVertex.position, surfaceVertex.normal);
}

static inline uint metal3DEmitSurfaceNetTriangle(device float *vertices,
                                                 uint vertexIndex,
                                                 Metal3DSurfaceNetVertex a,
                                                 Metal3DSurfaceNetVertex b,
                                                 Metal3DSurfaceNetVertex c)
{
    metal3DStoreSurfaceNetVertex(vertices, vertexIndex + 0, a);
    metal3DStoreSurfaceNetVertex(vertices, vertexIndex + 1, b);
    metal3DStoreSurfaceNetVertex(vertices, vertexIndex + 2, c);
    return vertexIndex + 3;
}

static inline uint metal3DMarchingCubesTriangleEdge(uint caseIndex, uint edgeSlot)
{
    const uint packedWord = kMetal3DMarchingCubesTriangles[caseIndex * 2u + (edgeSlot >> 3u)];
    return (packedWord >> ((edgeSlot & 7u) * 4u)) & 0xfu;
}

static inline uint metal3DMarchingCubesCaseIndex(thread const Metal3DSurfaceNetVertex *cubeVertices,
                                                 float threshold)
{
    uint caseIndex = 0;
    for (uint index = 0; index < 8; index++) {
        caseIndex |= cubeVertices[index].value >= threshold ? (1u << index) : 0u;
    }
    return caseIndex;
}

static inline uint metal3DMarchingCubesTriangleCount(uint caseIndex)
{
    uint triangleCount = 0;
    for (uint edgeSlot = 0; edgeSlot < 15; edgeSlot += 3) {
        const uint edgeA = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot);
        if (edgeA == 0xfu) {
            break;
        }

        const uint edgeB = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot + 1);
        const uint edgeC = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot + 2);
        if (edgeB == 0xfu || edgeC == 0xfu) {
            break;
        }
        triangleCount++;
    }
    return triangleCount;
}

static inline Metal3DSurfaceNetVertex metal3DMarchingCubesEdgeVertex(thread const Metal3DSurfaceNetVertex *cubeVertices,
                                                                     uint edgeIndex,
                                                                     float threshold)
{
    const uint cornerIndexA = uint(kMetal3DMarchingCubesEdgeCorners[edgeIndex * 2u + 0u]);
    const uint cornerIndexB = uint(kMetal3DMarchingCubesEdgeCorners[edgeIndex * 2u + 1u]);
    return metal3DInterpolateSurfaceVertex(cubeVertices[cornerIndexA], cubeVertices[cornerIndexB], threshold);
}

static inline uint metal3DEmitMarchingCubesSurface(device float *outputVertices,
                                                   uint vertexIndex,
                                                   thread const Metal3DSurfaceNetVertex *cubeVertices,
                                                   uint caseIndex,
                                                   float threshold)
{
    for (uint edgeSlot = 0; edgeSlot < 15; edgeSlot += 3) {
        const uint edgeA = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot);
        if (edgeA == 0xfu) {
            break;
        }

        const uint edgeB = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot + 1);
        const uint edgeC = metal3DMarchingCubesTriangleEdge(caseIndex, edgeSlot + 2);
        if (edgeB == 0xfu || edgeC == 0xfu) {
            break;
        }

        const Metal3DSurfaceNetVertex a = metal3DMarchingCubesEdgeVertex(cubeVertices, edgeA, threshold);
        const Metal3DSurfaceNetVertex b = metal3DMarchingCubesEdgeVertex(cubeVertices, edgeB, threshold);
        const Metal3DSurfaceNetVertex c = metal3DMarchingCubesEdgeVertex(cubeVertices, edgeC, threshold);
        vertexIndex = metal3DEmitSurfaceNetTriangle(outputVertices, vertexIndex, a, b, c);
    }

    return vertexIndex;
}

kernel void metal3DCountSurfaceMarchingCubes(device const float *volume [[buffer(0)]],
                                             device uint *triangleCounts [[buffer(1)]],
                                             constant Metal3DSurfaceExtractionUniforms &uniforms [[buffer(2)]],
                                             uint cellIndex [[thread_position_in_grid]])
{
    if (cellIndex >= uniforms.cellCount) {
        return;
    }

    const uint cellSlice = uniforms.cellWidth * uniforms.cellHeight;
    const uint cellZ = cellIndex / cellSlice;
    const uint remainder = cellIndex - cellZ * cellSlice;
    const uint cellY = remainder / uniforms.cellWidth;
    const uint cellX = remainder - cellY * uniforms.cellWidth;

    Metal3DSurfaceNetVertex cubeVertices[8];
    for (uint index = 0; index < 8; index++) {
        cubeVertices[index] = metal3DSurfaceCubeVertex(volume, uniforms, cellX, cellY, cellZ, index);
    }

    const uint caseIndex = metal3DMarchingCubesCaseIndex(cubeVertices, uniforms.threshold);
    triangleCounts[cellIndex] = metal3DMarchingCubesTriangleCount(caseIndex);
}

kernel void metal3DEmitSurfaceMarchingCubes(device const float *volume [[buffer(0)]],
                                            device const uint *triangleCounts [[buffer(1)]],
                                            device const uint *triangleOffsets [[buffer(2)]],
                                            device float *vertices [[buffer(3)]],
                                            constant Metal3DSurfaceExtractionUniforms &uniforms [[buffer(4)]],
                                            uint cellIndex [[thread_position_in_grid]])
{
    if (cellIndex >= uniforms.cellCount || triangleCounts[cellIndex] == 0) {
        return;
    }

    const uint cellSlice = uniforms.cellWidth * uniforms.cellHeight;
    const uint cellZ = cellIndex / cellSlice;
    const uint remainder = cellIndex - cellZ * cellSlice;
    const uint cellY = remainder / uniforms.cellWidth;
    const uint cellX = remainder - cellY * uniforms.cellWidth;

    Metal3DSurfaceNetVertex cubeVertices[8];
    for (uint index = 0; index < 8; index++) {
        cubeVertices[index] = metal3DSurfaceCubeVertex(volume, uniforms, cellX, cellY, cellZ, index);
    }

    uint vertexIndex = triangleOffsets[cellIndex] * 3;
    const uint caseIndex = metal3DMarchingCubesCaseIndex(cubeVertices, uniforms.threshold);
    metal3DEmitMarchingCubesSurface(vertices, vertexIndex, cubeVertices, caseIndex, uniforms.threshold);
}

struct Metal3DVisibilityUniforms {
    uint triangleCount;
    uint triangleBase;
    uint viewCount;
    uint gridWidth;
    uint gridHeight;
    uint gridVoxelCount;
    float xyCenterX;
    float xyCenterY;
    float xyRadius;
    float minimumZ;
    float zRange;
    float depthTolerance;
};

static inline float3 metal3DVisibilityVertex(device const float *vertices,
                                             uint triangleIndex,
                                             uint vertexSlot)
{
    const uint base = triangleIndex * 18u + vertexSlot * 6u;
    return float3(vertices[base + 0u], vertices[base + 1u], vertices[base + 2u]);
}

static inline uint metal3DVisibilityDepthValue(float depth,
                                               constant Metal3DVisibilityUniforms &uniforms)
{
    const float depthEncodingScale = 4294901760.0f;
    const float depthSpan = max(uniforms.xyRadius * 2.0f, 0.0001f);
    const float normalizedDepth = clamp((depth + uniforms.xyRadius) / depthSpan, 0.0f, 1.0f);
    return max(1u, uint(normalizedDepth * depthEncodingScale));
}

static inline uint metal3DVisibilityDepthTolerance(constant Metal3DVisibilityUniforms &uniforms)
{
    const float depthEncodingScale = 4294901760.0f;
    const float depthSpan = max(uniforms.xyRadius * 2.0f, 0.0001f);
    const float normalizedTolerance = clamp(uniforms.depthTolerance / depthSpan, 0.0f, 1.0f);
    return uint(normalizedTolerance * depthEncodingScale);
}

struct Metal3DVisibilityProjection {
    int2 pixel;
    uint encodedDepth;
};

static inline Metal3DVisibilityProjection metal3DVisibilityProject(float3 point,
                                                                   float2 viewForward,
                                                                   float2 viewRight,
                                                                   constant Metal3DVisibilityUniforms &uniforms)
{
    const float2 centeredXY = float2(point.x - uniforms.xyCenterX, point.y - uniforms.xyCenterY);
    const float u = dot(centeredXY, viewRight);
    const float v = point.z - uniforms.minimumZ;
    const float pixelX = ((u + uniforms.xyRadius) / max(uniforms.xyRadius * 2.0f, 0.0001f)) * float(uniforms.gridWidth - 1u);
    const float pixelY = (v / max(uniforms.zRange, 0.0001f)) * float(uniforms.gridHeight - 1u);
    Metal3DVisibilityProjection projection;
    projection.pixel = int2(
        clamp(int(floor(pixelX + 0.5f)), 0, int(uniforms.gridWidth) - 1),
        clamp(int(floor(pixelY + 0.5f)), 0, int(uniforms.gridHeight) - 1)
    );
    projection.encodedDepth = metal3DVisibilityDepthValue(dot(centeredXY, viewForward), uniforms);
    return projection;
}

static inline void metal3DSplatVisibilitySample(device atomic_uint *depthBuffer,
                                                float3 point,
                                                uint viewIndex,
                                                float2 viewForward,
                                                float2 viewRight,
                                                constant Metal3DVisibilityUniforms &uniforms)
{
    const Metal3DVisibilityProjection projection = metal3DVisibilityProject(point, viewForward, viewRight, uniforms);
    const uint viewOffset = viewIndex * uniforms.gridVoxelCount;
    const uint depthIndex = viewOffset + uint(projection.pixel.y) * uniforms.gridWidth + uint(projection.pixel.x);
    atomic_fetch_max_explicit(&depthBuffer[depthIndex], projection.encodedDepth, memory_order_relaxed);
}

static inline bool metal3DVisibilitySampleVisible(device atomic_uint *depthBuffer,
                                                  float3 point,
                                                  uint viewIndex,
                                                  float2 viewForward,
                                                  float2 viewRight,
                                                  constant Metal3DVisibilityUniforms &uniforms)
{
    const Metal3DVisibilityProjection projection = metal3DVisibilityProject(point, viewForward, viewRight, uniforms);
    uint frontDepth = 0u;
    bool foundDepth = false;
    const uint viewOffset = viewIndex * uniforms.gridVoxelCount;
    for (int dy = -1; dy <= 1; ++dy) {
        const int y = projection.pixel.y + dy;
        if (y < 0 || y >= int(uniforms.gridHeight)) {
            continue;
        }
        const uint rowOffset = uint(y) * uniforms.gridWidth;
        for (int dx = -1; dx <= 1; ++dx) {
            const int x = projection.pixel.x + dx;
            if (x < 0 || x >= int(uniforms.gridWidth)) {
                continue;
            }
            const uint depthIndex = viewOffset + rowOffset + uint(x);
            const uint candidateDepth = atomic_load_explicit(&depthBuffer[depthIndex], memory_order_relaxed);
            if (candidateDepth == 0u) {
                continue;
            }
            foundDepth = true;
            frontDepth = max(frontDepth, candidateDepth);
        }
    }

    const uint tolerance = metal3DVisibilityDepthTolerance(uniforms);
    return foundDepth && (projection.encodedDepth >= frontDepth || frontDepth - projection.encodedDepth <= tolerance);
}

kernel void metal3DSplatSurfaceVisibilityDepth(device const float *vertices [[buffer(0)]],
                                               device atomic_uint *depthBuffer [[buffer(1)]],
                                               constant Metal3DVisibilityUniforms &uniforms [[buffer(2)]],
                                               uint2 gridIndex [[thread_position_in_grid]])
{
    const uint triangleIndex = gridIndex.x;
    const uint viewIndex = gridIndex.y;
    if (viewIndex >= uniforms.viewCount) {
        return;
    }
    const uint sourceTriangleIndex = uniforms.triangleBase + triangleIndex;
    if (sourceTriangleIndex >= uniforms.triangleCount) {
        return;
    }

    const float angle = (float(viewIndex) / float(uniforms.viewCount)) * 6.28318530718f;
    const float2 viewForward = float2(cos(angle), sin(angle));
    const float2 viewRight = float2(-sin(angle), cos(angle));
    const float3 p0 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 0u);
    const float3 p1 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 1u);
    const float3 p2 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 2u);
    const float3 centroid = (p0 + p1 + p2) * (1.0f / 3.0f);
    metal3DSplatVisibilitySample(depthBuffer, centroid, viewIndex, viewForward, viewRight, uniforms);
    metal3DSplatVisibilitySample(depthBuffer, p0, viewIndex, viewForward, viewRight, uniforms);
    metal3DSplatVisibilitySample(depthBuffer, p1, viewIndex, viewForward, viewRight, uniforms);
    metal3DSplatVisibilitySample(depthBuffer, p2, viewIndex, viewForward, viewRight, uniforms);
}

kernel void metal3DMarkSurfaceVisibility(device const float *vertices [[buffer(0)]],
                                         device atomic_uint *depthBuffer [[buffer(1)]],
                                         device atomic_uint *visibleFlags [[buffer(2)]],
                                         constant Metal3DVisibilityUniforms &uniforms [[buffer(3)]],
                                         uint2 gridIndex [[thread_position_in_grid]])
{
    const uint triangleIndex = gridIndex.x;
    const uint viewIndex = gridIndex.y;
    if (viewIndex >= uniforms.viewCount) {
        return;
    }
    const uint sourceTriangleIndex = uniforms.triangleBase + triangleIndex;
    if (sourceTriangleIndex >= uniforms.triangleCount) {
        return;
    }

    const float angle = (float(viewIndex) / float(uniforms.viewCount)) * 6.28318530718f;
    const float2 viewForward = float2(cos(angle), sin(angle));
    const float2 viewRight = float2(-sin(angle), cos(angle));
    const float3 p0 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 0u);
    const float3 p1 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 1u);
    const float3 p2 = metal3DVisibilityVertex(vertices, sourceTriangleIndex, 2u);
    const float3 centroid = (p0 + p1 + p2) * (1.0f / 3.0f);
    if (metal3DVisibilitySampleVisible(depthBuffer, centroid, viewIndex, viewForward, viewRight, uniforms) ||
        metal3DVisibilitySampleVisible(depthBuffer, p0, viewIndex, viewForward, viewRight, uniforms) ||
        metal3DVisibilitySampleVisible(depthBuffer, p1, viewIndex, viewForward, viewRight, uniforms) ||
        metal3DVisibilitySampleVisible(depthBuffer, p2, viewIndex, viewForward, viewRight, uniforms)) {
        atomic_store_explicit(&visibleFlags[sourceTriangleIndex], 1u, memory_order_relaxed);
    }
}

struct Metal3DOverlayVertex {
    float3 position;
    float3 normal;
    float4 color;
};

struct Metal3DOverlayUniforms {
    float4x4 viewProjectionMatrix;
    float4 color;
};

struct Metal3DOverlayRasterizerData {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float4 color;
};

struct Metal3DFragmentOutput {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

static inline float metalViewerNormalizedValue(float value, float level, float width) {
    const float minValue = level - width * 0.5;
    return clamp((value - minValue) / max(width, 1e-5), 0.0, 1.0);
}

static inline float metalViewerGradientMagnitudeNormalized(
    texture3d<float, access::sample> texture,
    sampler metricSampler,
    float3 coord,
    float level,
    float width
) {
    const float3 delta = 1.0 / max(float3(texture.get_width() - 1, texture.get_height() - 1, texture.get_depth() - 1), float3(1.0));
    const float sampleX1 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord + float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r, level, width);
    const float sampleX0 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord - float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r, level, width);
    const float sampleY1 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord + float3(0.0, delta.y, 0.0), 0.0, 1.0)).r, level, width);
    const float sampleY0 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord - float3(0.0, delta.y, 0.0), 0.0, 1.0)).r, level, width);
    const float sampleZ1 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord + float3(0.0, 0.0, delta.z), 0.0, 1.0)).r, level, width);
    const float sampleZ0 = metalViewerNormalizedValue(texture.sample(metricSampler, clamp(coord - float3(0.0, 0.0, delta.z), 0.0, 1.0)).r, level, width);
    return length(float3(sampleX1 - sampleX0, sampleY1 - sampleY0, sampleZ1 - sampleZ0));
}

vertex RasterizerData metalViewerVertex(
    const device MetalVertex *vertices [[buffer(0)]],
    constant MetalUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    RasterizerData out;
    float2 scaledPosition = vertices[vertexID].position * uniforms.scale;
    const float drawableAspect = max(uniforms.drawableAspect, 0.0001);
    const float2 screenPosition = float2(scaledPosition.x * drawableAspect, scaledPosition.y);
    const float cosine = cos(uniforms.rotationRadians);
    const float sine = sin(uniforms.rotationRadians);
    const float2 rotatedScreenPosition = float2(
        screenPosition.x * cosine - screenPosition.y * sine,
        screenPosition.x * sine + screenPosition.y * cosine
    );
    const float2 rotatedPosition = float2(rotatedScreenPosition.x / drawableAspect, rotatedScreenPosition.y);
    out.position = float4(rotatedPosition + uniforms.offset, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

vertex RasterizerData metalPreviewVertex(
    const device MetalVertex *vertices [[buffer(0)]],
    constant MetalPreviewUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    RasterizerData out;
    float2 scaledPosition = vertices[vertexID].position * uniforms.scale + uniforms.offset;
    out.position = float4(scaledPosition, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

vertex MetalMPRRasterizerData metalViewerMPRVertex(
    const device MetalMPRVertex *vertices [[buffer(0)]],
    constant MetalMPRUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    MetalMPRRasterizerData out;
    out.position = uniforms.viewProjectionMatrix * float4(vertices[vertexID].position, 1.0);
    out.baseVoxel = vertices[vertexID].baseVoxel;
    out.color = vertices[vertexID].color;
    return out;
}

vertex MetalMPRBorderRasterizerData metalViewerMPRBorderVertex(
    const device MetalMPRVertex *vertices [[buffer(0)]],
    constant MetalMPRUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    MetalMPRBorderRasterizerData out;
    out.position = uniforms.viewProjectionMatrix * float4(vertices[vertexID].position, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

vertex MetalMPRRasterizerData metalViewerMPRPlaneHighlightVertex(
    const device MetalMPRVertex *vertices [[buffer(0)]],
    constant MetalMPRUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    MetalMPRRasterizerData out;
    out.position = uniforms.viewProjectionMatrix * float4(vertices[vertexID].position, 1.0);
    out.position.z = max(out.position.z - 0.0005 * out.position.w, 0.0);
    out.baseVoxel = vertices[vertexID].baseVoxel;
    out.color = vertices[vertexID].color;
    return out;
}

vertex Metal3DRasterizerData metal3DVolumeVertex(
    const device Metal3DVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]]
) {
    Metal3DRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.uv = vertices[vertexID].uv;
    return out;
}

vertex Metal3DOverlayRasterizerData metal3DOverlayVertexMain(
    const device Metal3DOverlayVertex *vertices [[buffer(0)]],
    constant Metal3DOverlayUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    Metal3DOverlayRasterizerData out;
    out.worldPosition = vertices[vertexID].position;
    out.normal = vertices[vertexID].normal;
    out.color = vertices[vertexID].color;
    out.position = uniforms.viewProjectionMatrix * float4(vertices[vertexID].position, 1.0);
    return out;
}

static inline bool metal3DIntersectBox(float3 rayOrigin, float3 rayDirection, float3 boxMin, float3 boxMax, thread float &tMin, thread float &tMax) {
    bool3 useOriginalDirection = abs(rayDirection) >= float3(1e-5);
    float3 safeDirection = select(float3(1e-5), rayDirection, useOriginalDirection);
    float3 inverseDirection = 1.0 / safeDirection;
    float3 t0 = (boxMin - rayOrigin) * inverseDirection;
    float3 t1 = (boxMax - rayOrigin) * inverseDirection;
    float3 tSmall = min(t0, t1);
    float3 tLarge = max(t0, t1);
    tMin = max(max(tSmall.x, tSmall.y), tSmall.z);
    tMax = min(min(tLarge.x, tLarge.y), tLarge.z);
    return tMax >= max(tMin, 0.0);
}

static inline float3 metal3DTextureCoordinate(float3 position, float3 boxMin, float3 boxMax) {
    return (position - boxMin) / (boxMax - boxMin);
}

static inline float metal3DOpacityAt(
    float scalar,
    float windowLevel,
    float windowWidth,
    texture2d<float> opacityTexture,
    sampler transferSampler
) {
    float minValue = windowLevel - windowWidth * 0.5;
    float normalizedScalar = clamp((scalar - minValue) / max(windowWidth, 1e-5), 0.0, 1.0);
    return opacityTexture.sample(transferSampler, float2(normalizedScalar, 0.5)).r;
}

static inline float metal3DRawOpacityAt(
    float scalar,
    float domainMin,
    float domainMax,
    texture2d<float> opacityTexture,
    sampler transferSampler
) {
    float normalizedScalar = clamp((scalar - domainMin) / max(domainMax - domainMin, 1e-5), 0.0, 1.0);
    return opacityTexture.sample(transferSampler, float2(normalizedScalar, 0.5)).r;
}

static inline float3 metal3DColorAt(
    float scalar,
    float windowLevel,
    float windowWidth,
    texture2d<float> clutTexture,
    sampler transferSampler
) {
    float minValue = windowLevel - windowWidth * 0.5;
    float normalizedScalar = clamp((scalar - minValue) / max(windowWidth, 1e-5), 0.0, 1.0);
    return clutTexture.sample(transferSampler, float2(normalizedScalar, 0.5)).rgb;
}

static inline float4 metal3DPreIntegratedTransferAt(
    float previousScalar,
    float currentScalar,
    float windowLevel,
    float windowWidth,
    float opacityDomainMin,
    float opacityDomainMax,
    uint useRawOpacityCurve,
    texture2d<float> preIntegratedTransferTexture,
    sampler transferSampler
) {
    float lowerBound = useRawOpacityCurve != 0 ? opacityDomainMin : windowLevel - windowWidth * 0.5;
    float upperBound = useRawOpacityCurve != 0 ? opacityDomainMax : lowerBound + max(windowWidth, 1e-5);
    float span = max(upperBound - lowerBound, 1e-5);
    float2 coord = clamp((float2(previousScalar, currentScalar) - lowerBound) / span, 0.0, 1.0);
    return preIntegratedTransferTexture.sample(transferSampler, coord);
}

static inline float3 metal3DBoneColor(float scalar, float lowerBound, float upperBound) {
    float t = clamp((scalar - lowerBound) / max(upperBound - lowerBound, 1e-5), 0.0, 1.0);
    float3 corticalBone = float3(0.62, 0.58, 0.44);
    float3 denseBone = float3(0.76, 0.71, 0.55);
    return mix(corticalBone, denseBone, t);
}

static inline float metal3DHash(float3 value) {
    return fract(sin(dot(value, float3(12.9898, 78.233, 45.164))) * 43758.5453);
}

static inline float3 metal3DGradient(
    float3 texCoord,
    texture3d<float> volumeTexture,
    sampler volumeSampler,
    uint3 dimensions,
    float3 voxelSpacing
) {
    float3 sampleRadius = float3(1.5, 1.5, 2.75);
    float3 delta = sampleRadius / max(float3(dimensions - uint3(1)), float3(1.0));
    float sampleX1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleX0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleY1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleY0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleZ1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    float sampleZ0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    return float3(sampleX1 - sampleX0, sampleY1 - sampleY0, sampleZ1 - sampleZ0) / max(sampleRadius * voxelSpacing, float3(0.0001));
}

fragment Metal3DFragmentOutput metal3DVolumeFragment(
    Metal3DRasterizerData in [[stage_in]],
    constant Metal3DVolumeUniforms &uniforms [[buffer(0)]],
    texture3d<float> volumeTexture [[texture(0)]],
    texture2d<float> clutTexture [[texture(1)]],
    texture2d<float> opacityTexture [[texture(2)]],
    texture2d<float> preIntegratedTransferTexture [[texture(3)]],
    texture3d<float> skinMaskTexture [[texture(4)]],
    sampler textureSampler [[sampler(0)]],
    sampler maskSampler [[sampler(1)]]
) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rayOrigin = uniforms.cameraPosition +
        ndc.x * uniforms.aspectRatio * uniforms.tanHalfFovY * uniforms.cameraRight +
        ndc.y * uniforms.tanHalfFovY * uniforms.cameraUp;
    float3 rayDirection = normalize(uniforms.cameraForward);

    float3 marchingBoxMin = uniforms.cropEnabled != 0 ? max(uniforms.boxMin, uniforms.cropBoxMin) : uniforms.boxMin;
    float3 marchingBoxMax = uniforms.cropEnabled != 0 ? min(uniforms.boxMax, uniforms.cropBoxMax) : uniforms.boxMax;

    float tMin = 0.0;
    float tMax = 0.0;
    if (!metal3DIntersectBox(rayOrigin, rayDirection, marchingBoxMin, marchingBoxMax, tMin, tMax)) {
        Metal3DFragmentOutput output;
        output.color = float4(0.0, 0.0, 0.0, 1.0);
        output.depth = 1.0;
        return output;
    }

    float4 accumulated = float4(0.0);
    float t = max(tMin, 0.0);
    float rayJitter = metal3DHash(float3(floor(in.position.xy), 19.19));
    t = min(t + uniforms.stepSize * rayJitter, tMax);
    float previousScalar = 0.0;
    float previousT = t;
    bool havePreviousScalar = false;
    float visibleDepth = 1.0;
    bool hasVisibleDepth = false;

    for (uint stepIndex = 0; stepIndex < uniforms.maxSteps && t <= tMax && accumulated.a <= (1.0 - 1.0 / 255.0); ++stepIndex, t += uniforms.stepSize) {
        float3 position = rayOrigin + rayDirection * t;
        float3 texCoord = metal3DTextureCoordinate(position, uniforms.boxMin, uniforms.boxMax);

        if (any(texCoord < 0.0) || any(texCoord > 1.0)) {
            continue;
        }

        if (uniforms.skinMaskEnabled != 0 && skinMaskTexture.sample(maskSampler, texCoord).r > 0.5) {
            previousT = t;
            havePreviousScalar = false;
            continue;
        }

        float scalar = volumeTexture.sample(textureSampler, texCoord).r;
        float opacity = 0.0;
        float3 color = float3(0.0);
        if (uniforms.boneRenderingOptions.x > 0.5) {
            if (scalar < uniforms.boneRenderingOptions.y || scalar > uniforms.boneRenderingOptions.z) {
                previousScalar = scalar;
                havePreviousScalar = true;
                continue;
            }
            const float surfaceThreshold = uniforms.boneRenderingOptions.w;
            const bool crossedSurface = (!havePreviousScalar && scalar >= surfaceThreshold) ||
                                        (havePreviousScalar && previousScalar < surfaceThreshold && scalar >= surfaceThreshold);
            if (!crossedSurface) {
                previousScalar = scalar;
                previousT = t;
                havePreviousScalar = true;
                continue;
            }

            float refinedNear = havePreviousScalar ? previousT : max(t - uniforms.stepSize, tMin);
            float refinedFar = t;
            float refinedScalar = scalar;
            float nearScalar = havePreviousScalar ? previousScalar : scalar;
            float farScalar = scalar;

            for (uint refineStep = 0; refineStep < 10; ++refineStep) {
                float refinedMid = 0.5 * (refinedNear + refinedFar);
                float3 refinedPosition = rayOrigin + rayDirection * refinedMid;
                float3 refinedCoord = metal3DTextureCoordinate(refinedPosition, uniforms.boxMin, uniforms.boxMax);
                refinedScalar = volumeTexture.sample(textureSampler, clamp(refinedCoord, 0.0, 1.0)).r;
                if (refinedScalar >= surfaceThreshold) {
                    refinedFar = refinedMid;
                    farScalar = refinedScalar;
                } else {
                    refinedNear = refinedMid;
                    nearScalar = refinedScalar;
                }
            }

            float scalarSpan = farScalar - nearScalar;
            float interpolation = 0.5;
            if (abs(scalarSpan) > 1e-5) {
                interpolation = clamp((surfaceThreshold - nearScalar) / scalarSpan, 0.0, 1.0);
            }
            float hitT = mix(refinedNear, refinedFar, interpolation);
            float3 hitPosition = rayOrigin + rayDirection * hitT;
            float3 hitCoord = metal3DTextureCoordinate(hitPosition, uniforms.boxMin, uniforms.boxMax);
            float hitScalar = mix(nearScalar, farScalar, interpolation);
            float hitOpacity = uniforms.useRawOpacityCurve != 0
                ? metal3DRawOpacityAt(hitScalar, uniforms.opacityDomainMin, uniforms.opacityDomainMax, opacityTexture, textureSampler)
                : metal3DOpacityAt(hitScalar, uniforms.windowLevel, uniforms.windowWidth, opacityTexture, textureSampler);
            float surfaceVisibility = smoothstep(0.02, 0.30, clamp(hitOpacity, 0.0, 1.0));
            if (surfaceVisibility <= 0.001) {
                previousScalar = scalar;
                previousT = t;
                havePreviousScalar = true;
                continue;
            }
            float dither = metal3DHash(floor(hitPosition * 220.0));
            if (surfaceVisibility < 0.999 && dither > surfaceVisibility) {
                previousScalar = scalar;
                previousT = t;
                havePreviousScalar = true;
                continue;
            }
            color = metal3DBoneColor(hitScalar, surfaceThreshold, uniforms.boneRenderingOptions.z);
            previousScalar = scalar;
            previousT = t;
            havePreviousScalar = true;
            float3 shadedColor = color;
            if (uniforms.shading > 0.5) {
                float3 gradient = metal3DGradient(hitCoord, volumeTexture, textureSampler, uniforms.volumeDimensions, uniforms.voxelSpacing);
                float gradientLength = length(gradient);
                if (gradientLength > 1e-5) {
                    float3 normal = normalize(gradient);
                    float3 viewDirection = normalize(-rayDirection);
                    if (dot(normal, viewDirection) < 0.0) {
                        normal = -normal;
                    }
                    float3 lightDirection = viewDirection;
                    float3 spotlightAxis = -viewDirection;
                    float spotCos = max(dot(spotlightAxis, uniforms.cameraForward), 0.0);
                    float spotFactor = smoothstep(0.72, 0.96, spotCos);
                    float diffuse = max(dot(normal, lightDirection), 0.0);
                    float facing = max(dot(normal, viewDirection), 0.0);
                    float3 halfVector = normalize(lightDirection + viewDirection);
                    float specular = pow(max(dot(normal, halfVector), 0.0), max(uniforms.specularPower, 1.0));
                    float lighting = clamp(uniforms.ambient + spotFactor * (uniforms.diffuse * diffuse + 0.10 * facing), 0.22, 0.62);
                    shadedColor *= lighting;
                    shadedColor += color * (uniforms.specular * specular * diffuse * spotFactor);
                    shadedColor = min(shadedColor, color * 0.78 + float3(0.045));
                }
            }
            Metal3DFragmentOutput output;
            output.color = float4(shadedColor, 1.0);
            float4 clipPosition = uniforms.viewProjectionMatrix * float4(hitPosition, 1.0);
            output.depth = saturate(clipPosition.z / clipPosition.w);
            return output;
        } else {
            if (uniforms.usePreIntegratedTransfer != 0) {
                float fromScalar = havePreviousScalar ? previousScalar : scalar;
                float4 transfer = metal3DPreIntegratedTransferAt(
                    fromScalar,
                    scalar,
                    uniforms.windowLevel,
                    uniforms.windowWidth,
                    uniforms.opacityDomainMin,
                    uniforms.opacityDomainMax,
                    uniforms.useRawOpacityCurve,
                    preIntegratedTransferTexture,
                    textureSampler
                );
                opacity = transfer.a;
                color = transfer.rgb;
            } else {
                opacity = metal3DOpacityAt(scalar, uniforms.windowLevel, uniforms.windowWidth, opacityTexture, textureSampler);
                color = metal3DColorAt(scalar, uniforms.windowLevel, uniforms.windowWidth, clutTexture, textureSampler) * opacity;
            }
            if (opacity <= 0.0) {
                previousScalar = scalar;
                previousT = t;
                havePreviousScalar = true;
                continue;
            }
            previousScalar = scalar;
            previousT = t;
            havePreviousScalar = true;
        }
        if (uniforms.shading > 0.5) {
            float3 gradient = metal3DGradient(texCoord, volumeTexture, textureSampler, uniforms.volumeDimensions, uniforms.voxelSpacing);
            float gradientLength = length(gradient);
            if (gradientLength > 1e-5) {
                float3 normal = normalize(gradient);
                float3 viewDirection = normalize(-rayDirection);
                if (dot(normal, viewDirection) < 0.0) {
                    normal = -normal;
                }
                float3 lightDirection = viewDirection;
                float3 spotlightAxis = -viewDirection;
                float spotCos = max(dot(spotlightAxis, uniforms.cameraForward), 0.0);
                float spotFactor = smoothstep(0.72, 0.96, spotCos);
                float diffuse = max(dot(normal, lightDirection), 0.0);
                float3 halfVector = normalize(lightDirection + viewDirection);
                float specular = pow(max(dot(normal, halfVector), 0.0), max(uniforms.specularPower, 1.0));
                color *= clamp(uniforms.ambient + uniforms.diffuse * diffuse * spotFactor, 0.20, 0.90);
                color += opacity * uniforms.specular * specular * spotFactor;
            }
        }

        float sampleAlpha = clamp(opacity, 0.0, 1.0);
        if (sampleAlpha <= 0.0) {
            continue;
        }
        accumulated.rgb += (1.0 - accumulated.a) * color;
        accumulated.a += (1.0 - accumulated.a) * sampleAlpha;
        if (!hasVisibleDepth && accumulated.a >= 0.02) {
            float4 clipPosition = uniforms.viewProjectionMatrix * float4(position, 1.0);
            visibleDepth = saturate(clipPosition.z / clipPosition.w);
            hasVisibleDepth = true;
        }
    }

    if (accumulated.a <= max(uniforms.alphaFloor, 0.0001)) {
        Metal3DFragmentOutput output;
        output.color = float4(0.0, 0.0, 0.0, 1.0);
        output.depth = 1.0;
        return output;
    }

    float3 finalColor = accumulated.rgb;
    Metal3DFragmentOutput output;
    output.color = float4(finalColor, 1.0);
    output.depth = hasVisibleDepth ? visibleDepth : 0.9999;
    return output;
}

fragment float4 metal3DOverlayFragment(
    Metal3DOverlayRasterizerData in [[stage_in]],
    constant Metal3DOverlayUniforms &uniforms [[buffer(1)]]
) {
    if (length_squared(in.normal) < 1e-6) {
        return float4(in.color.rgb, uniforms.color.a);
    }

    float3 normal = normalize(in.normal);
    const float3 lightDirection = normalize(float3(0.35, 0.55, 1.0));
    const float3 viewDirection = normalize(float3(0.0, 0.0, 1.0));
    const float diffuse = max(dot(normal, lightDirection), 0.0);
    const float3 halfVector = normalize(lightDirection + viewDirection);
    const float specular = pow(max(dot(normal, halfVector), 0.0), 24.0);
    const float fresnel = pow(1.0 - max(dot(normal, viewDirection), 0.0), 3.0);

    float lighting = 0.28 + 0.72 * diffuse;
    float3 color = in.color.rgb * lighting;
    color += in.color.rgb * (0.18 * fresnel);
    color += float3(1.0) * (0.25 * specular);
    color = min(color, float3(1.0));
    return float4(color, in.color.a * uniforms.color.a);
}

static float metalViewerSinc(float x) {
    x = abs(x);
    if (x < 1.0e-5) {
        return 1.0;
    }
    const float pix = 3.14159265358979323846 * x;
    return sin(pix) / pix;
}

static float metalViewerLanczosWeight(float x) {
    x = abs(x);
    if (x >= 3.0) {
        return 0.0;
    }
    return metalViewerSinc(x) * metalViewerSinc(x / 3.0);
}

static float metalViewerApplyOpacity(
    float normalizedValue,
    texture2d<float> opacityTexture,
    sampler imageSampler
) {
    return opacityTexture.sample(imageSampler, float2(clamp(normalizedValue, 0.0, 1.0), 0.5)).r;
}

static float3 metalViewerApplyCLUT(
    float normalizedValue,
    texture2d<float> clutTexture,
    sampler imageSampler
) {
    return clutTexture.sample(imageSampler, float2(clamp(normalizedValue, 0.0, 1.0), 0.5)).rgb;
}

static float3 metalViewerFusionColor(
    float mappedValue,
    float3 clutColor,
    uint hasCustomCLUT,
    bool isOverlay
) {
    if (hasCustomCLUT != 0) {
        return clutColor;
    }
    return isOverlay ? float3(mappedValue, 0.0, 0.0) : float3(0.0, mappedValue, 0.0);
}

static inline float metalViewerRescaleStoredVolumeValue(
    float storedValue,
    constant MetalUniforms &uniforms
) {
    return storedValue * uniforms.baseVolumeRescaleSlope + uniforms.baseVolumeRescaleIntercept;
}

static inline float metalViewerReadStoredVolumeSigned(
    texture3d<int, access::read> storedTexture,
    uint x,
    uint y,
    uint z,
    constant MetalUniforms &uniforms
) {
    return metalViewerRescaleStoredVolumeValue(float(storedTexture.read(uint3(x, y, z)).r), uniforms);
}

static inline float metalViewerReadStoredVolumeUnsigned(
    texture3d<uint, access::read> storedTexture,
    uint x,
    uint y,
    uint z,
    constant MetalUniforms &uniforms
) {
    return metalViewerRescaleStoredVolumeValue(float(storedTexture.read(uint3(x, y, z)).r), uniforms);
}

static inline float metalViewerSampleStoredVolumeSigned(
    texture3d<int, access::read> storedTexture,
    float2 texCoord,
    float sliceIndex,
    uint interpolationMode,
    constant MetalUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const uint depth = max(storedTexture.get_depth(), 1u);
    const float2 maximumPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maximumPosition);
    const uint z = uint(clamp(sliceIndex, 0.0, float(depth - 1u)));
    if (interpolationMode == kMetalViewerInterpolationLanczos) {
        const float2 sourceFootprint = fwidth(texCoord) * float2(float(width), float(height));
        if (max(sourceFootprint.x, sourceFootprint.y) <= 1.0) {
            const int2 basePixel = int2(floor(position));
            float weightedValue = 0.0;
            float totalWeight = 0.0;
            float minimumSample = 3.402823466e+38F;
            float maximumSample = -3.402823466e+38F;

            for (int yOffset = -2; yOffset <= 3; ++yOffset) {
                const int sampleY = basePixel.y + yOffset;
                const float yWeight = metalViewerLanczosWeight(position.y - float(sampleY));
                const uint clampedY = uint(clamp(sampleY, 0, int(height) - 1));
                for (int xOffset = -2; xOffset <= 3; ++xOffset) {
                    const int sampleX = basePixel.x + xOffset;
                    const float xWeight = metalViewerLanczosWeight(position.x - float(sampleX));
                    const float weight = xWeight * yWeight;
                    const uint clampedX = uint(clamp(sampleX, 0, int(width) - 1));
                    const float sampleValue = metalViewerReadStoredVolumeSigned(
                        storedTexture,
                        clampedX,
                        clampedY,
                        z,
                        uniforms
                    );
                    weightedValue += sampleValue * weight;
                    totalWeight += weight;
                    minimumSample = min(minimumSample, sampleValue);
                    maximumSample = max(maximumSample, sampleValue);
                }
            }

            if (abs(totalWeight) >= 1.0e-5) {
                return clamp(weightedValue / totalWeight, minimumSample, maximumSample);
            }
        }
    }
    if (interpolationMode == kMetalViewerInterpolationNearest) {
        const uint2 nearest = uint2(round(position));
        return metalViewerReadStoredVolumeSigned(storedTexture, nearest.x, nearest.y, z, uniforms);
    }
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);
    const float v00 = metalViewerReadStoredVolumeSigned(storedTexture, base.x, base.y, z, uniforms);
    const float v10 = metalViewerReadStoredVolumeSigned(storedTexture, next.x, base.y, z, uniforms);
    const float v01 = metalViewerReadStoredVolumeSigned(storedTexture, base.x, next.y, z, uniforms);
    const float v11 = metalViewerReadStoredVolumeSigned(storedTexture, next.x, next.y, z, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

static inline float metalViewerSampleStoredVolumeUnsigned(
    texture3d<uint, access::read> storedTexture,
    float2 texCoord,
    float sliceIndex,
    uint interpolationMode,
    constant MetalUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const uint depth = max(storedTexture.get_depth(), 1u);
    const float2 maximumPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maximumPosition);
    const uint z = uint(clamp(sliceIndex, 0.0, float(depth - 1u)));
    if (interpolationMode == kMetalViewerInterpolationLanczos) {
        const float2 sourceFootprint = fwidth(texCoord) * float2(float(width), float(height));
        if (max(sourceFootprint.x, sourceFootprint.y) <= 1.0) {
            const int2 basePixel = int2(floor(position));
            float weightedValue = 0.0;
            float totalWeight = 0.0;
            float minimumSample = 3.402823466e+38F;
            float maximumSample = -3.402823466e+38F;

            for (int yOffset = -2; yOffset <= 3; ++yOffset) {
                const int sampleY = basePixel.y + yOffset;
                const float yWeight = metalViewerLanczosWeight(position.y - float(sampleY));
                const uint clampedY = uint(clamp(sampleY, 0, int(height) - 1));
                for (int xOffset = -2; xOffset <= 3; ++xOffset) {
                    const int sampleX = basePixel.x + xOffset;
                    const float xWeight = metalViewerLanczosWeight(position.x - float(sampleX));
                    const float weight = xWeight * yWeight;
                    const uint clampedX = uint(clamp(sampleX, 0, int(width) - 1));
                    const float sampleValue = metalViewerReadStoredVolumeUnsigned(
                        storedTexture,
                        clampedX,
                        clampedY,
                        z,
                        uniforms
                    );
                    weightedValue += sampleValue * weight;
                    totalWeight += weight;
                    minimumSample = min(minimumSample, sampleValue);
                    maximumSample = max(maximumSample, sampleValue);
                }
            }

            if (abs(totalWeight) >= 1.0e-5) {
                return clamp(weightedValue / totalWeight, minimumSample, maximumSample);
            }
        }
    }
    if (interpolationMode == kMetalViewerInterpolationNearest) {
        const uint2 nearest = uint2(round(position));
        return metalViewerReadStoredVolumeUnsigned(storedTexture, nearest.x, nearest.y, z, uniforms);
    }
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);
    const float v00 = metalViewerReadStoredVolumeUnsigned(storedTexture, base.x, base.y, z, uniforms);
    const float v10 = metalViewerReadStoredVolumeUnsigned(storedTexture, next.x, base.y, z, uniforms);
    const float v01 = metalViewerReadStoredVolumeUnsigned(storedTexture, base.x, next.y, z, uniforms);
    const float v11 = metalViewerReadStoredVolumeUnsigned(storedTexture, next.x, next.y, z, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

fragment float4 metalViewerFragment(
    RasterizerData in [[stage_in]],
    constant MetalUniforms &uniforms [[buffer(0)]],
    texture3d<float> overlayTexture [[texture(1)]],
    texture3d<float> baseVolumeTexture [[texture(2)]],
    texture2d<float> baseCLUTTexture [[texture(3)]],
    texture2d<float> baseOpacityTexture [[texture(4)]],
    texture2d<float> overlayCLUTTexture [[texture(5)]],
    texture2d<float> overlayOpacityTexture [[texture(6)]],
    texture3d<int, access::read> signedBaseVolumeTexture [[texture(7)]],
    texture3d<uint, access::read> unsignedBaseVolumeTexture [[texture(8)]],
    sampler imageSampler [[sampler(0)]]
) {
    const float x = in.texCoord.x * max(float(uniforms.fixedVolumeSize.x) - 1.0, 0.0);
    const float y = in.texCoord.y * max(float(uniforms.fixedVolumeSize.y) - 1.0, 0.0);
    const float z = uniforms.currentSliceIndex;
    const float3 fixedVoxelCoordinate = float3(x, y, z);
    float basePixelValue = 0.0;
    if (uniforms.baseVolumeTextureKind == 2u) {
        basePixelValue = metalViewerSampleStoredVolumeSigned(
            signedBaseVolumeTexture,
            in.texCoord,
            uniforms.currentSliceIndex,
            uniforms.imageInterpolationMode,
            uniforms
        );
    } else if (uniforms.baseVolumeTextureKind == 3u) {
        basePixelValue = metalViewerSampleStoredVolumeUnsigned(
            unsignedBaseVolumeTexture,
            in.texCoord,
            uniforms.currentSliceIndex,
            uniforms.imageInterpolationMode,
            uniforms
        );
    } else {
        basePixelValue = baseVolumeTexture.sample(
            imageSampler,
            (fixedVoxelCoordinate + 0.5) / max(float3(baseVolumeTexture.get_width(), baseVolumeTexture.get_height(), baseVolumeTexture.get_depth()), float3(1.0))
        ).r;
    }
    const float baseMinValue = uniforms.baseWindowLevel - uniforms.baseWindowWidth * 0.5;
    const float baseNormalized = clamp((basePixelValue - baseMinValue) / uniforms.baseWindowWidth, 0.0, 1.0);
    const float baseMapped = metalViewerApplyOpacity(baseNormalized, baseOpacityTexture, imageSampler);
    const float3 baseColor = metalViewerApplyCLUT(baseMapped, baseCLUTTexture, imageSampler);

    if (uniforms.hasOverlay == 0) {
        return float4(baseColor, 1.0);
    }

    const float4 fixedVoxel = float4(fixedVoxelCoordinate, 1.0);
    const float4 worldPoint = uniforms.fixedVoxelToWorld * fixedVoxel;
    const float3 translatedWorldPoint = worldPoint.xyz - uniforms.overlayTranslationWorld;
    const float3 centeredWorldPoint = translatedWorldPoint - uniforms.movingRotationCenterWorld;
    const float4 rotatedWorldPoint = uniforms.movingInverseRotation * float4(centeredWorldPoint, 1.0);
    const float4 movingVoxel = uniforms.movingWorldToVoxel * float4(rotatedWorldPoint.xyz + uniforms.movingRotationCenterWorld, 1.0);
    const float3 overlaySize = float3(overlayTexture.get_width(), overlayTexture.get_height(), overlayTexture.get_depth());
    const float3 overlayCoord = (movingVoxel.xyz + 0.5) / overlaySize;

    if (overlayCoord.x < 0.0 || overlayCoord.x > 1.0 ||
        overlayCoord.y < 0.0 || overlayCoord.y > 1.0 ||
        overlayCoord.z < 0.0 || overlayCoord.z > 1.0) {
        const float3 baseFusionColor = metalViewerFusionColor(
            baseMapped,
            baseColor,
            uniforms.baseHasCustomCLUT,
            false
        );
        return float4(baseFusionColor * (1.0 - uniforms.overlayBlend), 1.0);
    }

    const float overlayPixelValue = overlayTexture.sample(imageSampler, overlayCoord).r;
    const float overlayMinValue = uniforms.overlayWindowLevel - uniforms.overlayWindowWidth * 0.5;
    const float overlayNormalized = clamp((overlayPixelValue - overlayMinValue) / uniforms.overlayWindowWidth, 0.0, 1.0);
    const float overlayMapped = metalViewerApplyOpacity(overlayNormalized, overlayOpacityTexture, imageSampler);
    const float3 overlayColor = metalViewerApplyCLUT(overlayMapped, overlayCLUTTexture, imageSampler);
    const float3 baseFusionColor = metalViewerFusionColor(baseMapped, baseColor, uniforms.baseHasCustomCLUT, false);
    const float3 overlayFusionColor = metalViewerFusionColor(overlayMapped, overlayColor, uniforms.overlayHasCustomCLUT, true);

    return float4(
        overlayFusionColor * uniforms.overlayBlend + baseFusionColor * (1.0 - uniforms.overlayBlend),
        1.0
    );
}

static float metalViewerCubicWeight(float x) {
    x = abs(x);
    if (x <= 1.0) {
        return (1.5 * x - 2.5) * x * x + 1.0;
    }
    if (x < 2.0) {
        return ((-0.5 * x + 2.5) * x - 4.0) * x + 2.0;
    }
    return 0.0;
}

static float metalViewerMPRSample(
    texture3d<float> volumeTexture,
    sampler imageSampler,
    float3 normalizedCoord
) {
    const float depth = float(volumeTexture.get_depth());
    if (depth < 4.0) {
        return volumeTexture.sample(imageSampler, normalizedCoord).r;
    }

    const float z = normalizedCoord.z * depth - 0.5;
    const float zBase = floor(z);
    const float zFraction = z - zBase;
    float weightedValue = 0.0;
    float totalWeight = 0.0;
    float minimumSample = 3.402823466e+38F;
    float maximumSample = -3.402823466e+38F;

    for (int offset = -1; offset <= 2; ++offset) {
        const float sampleZ = clamp(zBase + float(offset), 0.0, depth - 1.0);
        const float weight = metalViewerCubicWeight(float(offset) - zFraction);
        const float3 sampleCoord = float3(
            normalizedCoord.xy,
            (sampleZ + 0.5) / depth
        );
        const float sampleValue = volumeTexture.sample(imageSampler, sampleCoord).r;
        weightedValue += sampleValue * weight;
        totalWeight += weight;
        minimumSample = min(minimumSample, sampleValue);
        maximumSample = max(maximumSample, sampleValue);
    }

    return clamp(weightedValue / max(totalWeight, 0.0001), minimumSample, maximumSample);
}

fragment float4 metalViewerMPRFragment(
    MetalMPRRasterizerData in [[stage_in]],
    constant MetalMPRUniforms &uniforms [[buffer(0)]],
    texture3d<float> baseTexture [[texture(0)]],
    texture3d<float> overlayTexture [[texture(1)]],
    texture2d<float> baseCLUTTexture [[texture(3)]],
    texture2d<float> baseOpacityTexture [[texture(4)]],
    texture2d<float> overlayCLUTTexture [[texture(5)]],
    texture2d<float> overlayOpacityTexture [[texture(6)]],
    sampler imageSampler [[sampler(0)]]
) {
    const float3 baseSize = float3(baseTexture.get_width(), baseTexture.get_height(), baseTexture.get_depth());
    const float3 baseCoord = (in.baseVoxel + 0.5) / baseSize;

    if (baseCoord.x < 0.0 || baseCoord.x > 1.0 ||
        baseCoord.y < 0.0 || baseCoord.y > 1.0 ||
        baseCoord.z < 0.0 || baseCoord.z > 1.0) {
        discard_fragment();
    }

    const float basePixelValue = metalViewerMPRSample(baseTexture, imageSampler, baseCoord);
    const float baseMinValue = uniforms.baseWindowLevel - uniforms.baseWindowWidth * 0.5;
    const float baseNormalized = clamp((basePixelValue - baseMinValue) / uniforms.baseWindowWidth, 0.0, 1.0);
    const float baseMapped = metalViewerApplyOpacity(baseNormalized, baseOpacityTexture, imageSampler);
    const float3 baseColor = metalViewerApplyCLUT(baseMapped, baseCLUTTexture, imageSampler);

    if (uniforms.hasOverlay == 0) {
        return float4(baseColor, 1.0);
    }

    const float4 fixedVoxel = float4(in.baseVoxel, 1.0);
    const float4 worldPoint = uniforms.fixedVoxelToWorld * fixedVoxel;
    const float3 translatedWorldPoint = worldPoint.xyz - uniforms.overlayTranslationWorld;
    const float3 centeredWorldPoint = translatedWorldPoint - uniforms.movingRotationCenterWorld;
    const float4 rotatedWorldPoint = uniforms.movingInverseRotation * float4(centeredWorldPoint, 1.0);
    const float4 movingVoxel = uniforms.movingWorldToVoxel * float4(rotatedWorldPoint.xyz + uniforms.movingRotationCenterWorld, 1.0);
    const float3 overlaySize = float3(overlayTexture.get_width(), overlayTexture.get_height(), overlayTexture.get_depth());
    const float3 overlayCoord = (movingVoxel.xyz + 0.5) / overlaySize;

    if (overlayCoord.x < 0.0 || overlayCoord.x > 1.0 ||
        overlayCoord.y < 0.0 || overlayCoord.y > 1.0 ||
        overlayCoord.z < 0.0 || overlayCoord.z > 1.0) {
        const float3 baseFusionColor = metalViewerFusionColor(
            baseMapped,
            baseColor,
            uniforms.baseHasCustomCLUT,
            false
        );
        return float4(baseFusionColor, 1.0);
    }

    const float overlayPixelValue = metalViewerMPRSample(overlayTexture, imageSampler, overlayCoord);
    const float overlayMinValue = uniforms.overlayWindowLevel - uniforms.overlayWindowWidth * 0.5;
    const float overlayNormalized = clamp((overlayPixelValue - overlayMinValue) / uniforms.overlayWindowWidth, 0.0, 1.0);
    const float overlayMapped = metalViewerApplyOpacity(overlayNormalized, overlayOpacityTexture, imageSampler);
    const float3 overlayColor = metalViewerApplyCLUT(overlayMapped, overlayCLUTTexture, imageSampler);
    const float3 baseFusionColor = metalViewerFusionColor(baseMapped, baseColor, uniforms.baseHasCustomCLUT, false);
    const float3 overlayFusionColor = metalViewerFusionColor(overlayMapped, overlayColor, uniforms.overlayHasCustomCLUT, true);

    return float4(
        overlayFusionColor * uniforms.overlayBlend + baseFusionColor * (1.0 - uniforms.overlayBlend),
        1.0
    );
}

fragment float4 metalViewerMPRBorderFragment(
    MetalMPRBorderRasterizerData in [[stage_in]]
) {
    return in.color;
}

fragment float4 metalViewerMPRIntersectionFragment(
    MetalMPRBorderRasterizerData in [[stage_in]]
) {
    return in.color;
}

fragment float4 metalViewerMPRPlaneHighlightFragment(
    MetalMPRRasterizerData in [[stage_in]]
) {
    return in.color;
}

static inline float metalPreviewApplyStoredRescale(float storedValue, constant MetalPreviewUniforms &uniforms)
{
    return storedValue * uniforms.rescaleSlope + uniforms.rescaleIntercept;
}

static inline float metalPreviewReadStoredSigned(
    texture3d<int, access::read> storedTexture,
    uint x,
    uint y,
    uint z,
    constant MetalPreviewUniforms &uniforms
) {
    return metalPreviewApplyStoredRescale(float(storedTexture.read(uint3(x, y, z)).r), uniforms);
}

static inline float metalPreviewReadStoredUnsigned(
    texture3d<uint, access::read> storedTexture,
    uint x,
    uint y,
    uint z,
    constant MetalPreviewUniforms &uniforms
) {
    return metalPreviewApplyStoredRescale(float(storedTexture.read(uint3(x, y, z)).r), uniforms);
}

static inline float metalPreviewSampleStoredSigned(
    texture3d<int, access::read> storedTexture,
    float2 texCoord,
    float sliceIndex,
    constant MetalPreviewUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const uint depth = max(storedTexture.get_depth(), 1u);
    const float2 maxPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maxPosition);
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);
    const uint z = uint(clamp(sliceIndex, 0.0, float(depth - 1u)));

    const float v00 = metalPreviewReadStoredSigned(storedTexture, base.x, base.y, z, uniforms);
    const float v10 = metalPreviewReadStoredSigned(storedTexture, next.x, base.y, z, uniforms);
    const float v01 = metalPreviewReadStoredSigned(storedTexture, base.x, next.y, z, uniforms);
    const float v11 = metalPreviewReadStoredSigned(storedTexture, next.x, next.y, z, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

static inline float metalPreviewSampleStoredUnsigned(
    texture3d<uint, access::read> storedTexture,
    float2 texCoord,
    float sliceIndex,
    constant MetalPreviewUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const uint depth = max(storedTexture.get_depth(), 1u);
    const float2 maxPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maxPosition);
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);
    const uint z = uint(clamp(sliceIndex, 0.0, float(depth - 1u)));

    const float v00 = metalPreviewReadStoredUnsigned(storedTexture, base.x, base.y, z, uniforms);
    const float v10 = metalPreviewReadStoredUnsigned(storedTexture, next.x, base.y, z, uniforms);
    const float v01 = metalPreviewReadStoredUnsigned(storedTexture, base.x, next.y, z, uniforms);
    const float v11 = metalPreviewReadStoredUnsigned(storedTexture, next.x, next.y, z, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

static inline float metalPreviewReadStoredSigned2D(
    texture2d<int, access::read> storedTexture,
    uint x,
    uint y,
    constant MetalPreviewUniforms &uniforms
) {
    return metalPreviewApplyStoredRescale(float(storedTexture.read(uint2(x, y)).r), uniforms);
}

static inline float metalPreviewReadStoredUnsigned2D(
    texture2d<uint, access::read> storedTexture,
    uint x,
    uint y,
    constant MetalPreviewUniforms &uniforms
) {
    return metalPreviewApplyStoredRescale(float(storedTexture.read(uint2(x, y)).r), uniforms);
}

static inline float metalPreviewSampleStoredSigned2D(
    texture2d<int, access::read> storedTexture,
    float2 texCoord,
    constant MetalPreviewUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const float2 maxPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maxPosition);
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);

    const float v00 = metalPreviewReadStoredSigned2D(storedTexture, base.x, base.y, uniforms);
    const float v10 = metalPreviewReadStoredSigned2D(storedTexture, next.x, base.y, uniforms);
    const float v01 = metalPreviewReadStoredSigned2D(storedTexture, base.x, next.y, uniforms);
    const float v11 = metalPreviewReadStoredSigned2D(storedTexture, next.x, next.y, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

static inline float metalPreviewSampleStoredUnsigned2D(
    texture2d<uint, access::read> storedTexture,
    float2 texCoord,
    constant MetalPreviewUniforms &uniforms
) {
    const uint width = max(storedTexture.get_width(), 1u);
    const uint height = max(storedTexture.get_height(), 1u);
    const float2 maxPosition = float2(float(width - 1u), float(height - 1u));
    const float2 position = clamp(texCoord * float2(float(width), float(height)) - 0.5, float2(0.0), maxPosition);
    const uint2 base = uint2(floor(position));
    const uint2 next = min(base + uint2(1u), uint2(width - 1u, height - 1u));
    const float2 fraction = position - float2(base);

    const float v00 = metalPreviewReadStoredUnsigned2D(storedTexture, base.x, base.y, uniforms);
    const float v10 = metalPreviewReadStoredUnsigned2D(storedTexture, next.x, base.y, uniforms);
    const float v01 = metalPreviewReadStoredUnsigned2D(storedTexture, base.x, next.y, uniforms);
    const float v11 = metalPreviewReadStoredUnsigned2D(storedTexture, next.x, next.y, uniforms);
    return mix(mix(v00, v10, fraction.x), mix(v01, v11, fraction.x), fraction.y);
}

fragment float4 metalPreviewFragment(
    RasterizerData in [[stage_in]],
    constant MetalPreviewUniforms &uniforms [[buffer(0)]],
    texture3d<int, access::read> signedVolumeTexture [[texture(2)]],
    texture3d<uint, access::read> unsignedVolumeTexture [[texture(3)]],
    texture2d<int, access::read> signedImageTexture [[texture(4)]],
    texture2d<uint, access::read> unsignedImageTexture [[texture(5)]]
) {
    float pixelValue = 0.0;
    if (uniforms.useVolumeTexture == 0) {
        if (uniforms.volumeTextureKind == 2u) {
            pixelValue = metalPreviewSampleStoredSigned2D(signedImageTexture, in.texCoord, uniforms);
        } else if (uniforms.volumeTextureKind == 3u) {
            pixelValue = metalPreviewSampleStoredUnsigned2D(unsignedImageTexture, in.texCoord, uniforms);
        }
    } else if (uniforms.volumeTextureKind == 2u) {
        pixelValue = metalPreviewSampleStoredSigned(signedVolumeTexture, in.texCoord, uniforms.currentSliceIndex, uniforms);
    } else if (uniforms.volumeTextureKind == 3u) {
        pixelValue = metalPreviewSampleStoredUnsigned(unsignedVolumeTexture, in.texCoord, uniforms.currentSliceIndex, uniforms);
    }
    float minValue = uniforms.windowLevel - uniforms.windowWidth * 0.5;
    float normalized = clamp((pixelValue - minValue) / max(uniforms.windowWidth, 1e-5), 0.0, 1.0);
    return float4(normalized, normalized, normalized, 1.0);
}

kernel void metalViewerRegistrationJointHistogram(
    texture3d<float, access::sample> baseTexture [[texture(0)]],
    texture3d<float, access::sample> overlayTexture [[texture(1)]],
    constant RegistrationUniforms &uniforms [[buffer(0)]],
    device atomic_uint *jointHistogram [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x < uniforms.baseTextureSize.x && gid.y < uniforms.baseTextureSize.y && gid.z < uniforms.baseTextureSize.z) {
        constexpr sampler metricSampler(coord::normalized, address::clamp_to_zero, filter::linear);

        const float3 baseSize = float3(uniforms.baseTextureSize);
        const float3 baseCoord = (float3(gid) + 0.5) / baseSize;
        const float4 fixedVoxel = float4(float3(gid), 1.0);
        const float4 worldPoint = uniforms.fixedVoxelToWorld * fixedVoxel;
        const float3 translatedWorldPoint = worldPoint.xyz - uniforms.overlayTranslationWorld;
        const float3 centeredWorldPoint = translatedWorldPoint - uniforms.movingRotationCenterWorld;
        const float4 rotatedWorldPoint = uniforms.movingInverseRotation * float4(centeredWorldPoint, 1.0);
        const float4 movingVoxel = uniforms.movingWorldToVoxel * float4(rotatedWorldPoint.xyz + uniforms.movingRotationCenterWorld, 1.0);
        const float3 overlaySize = float3(overlayTexture.get_width(), overlayTexture.get_height(), overlayTexture.get_depth());
        const float3 overlayCoord = (movingVoxel.xyz + 0.5) / overlaySize;

        if (overlayCoord.x >= 0.0 && overlayCoord.x <= 1.0 &&
            overlayCoord.y >= 0.0 && overlayCoord.y <= 1.0 &&
            overlayCoord.z >= 0.0 && overlayCoord.z <= 1.0) {
            const float basePixelValue = baseTexture.sample(metricSampler, baseCoord).r;
            const float overlayPixelValue = overlayTexture.sample(metricSampler, overlayCoord).r;

            if (uniforms.metricOptions.x > 0.5 && uniforms.metricOptions.x < 1.5) {
                const float boneLower = uniforms.metricOptions.y;
                const float boneUpper = uniforms.metricOptions.z;
                const bool baseIsBone = basePixelValue >= boneLower && basePixelValue <= boneUpper;
                const bool overlayIsBone = overlayPixelValue >= boneLower && overlayPixelValue <= boneUpper;
                if (!(baseIsBone && overlayIsBone)) {
                    return;
                }
            }

            if (uniforms.metricOptions.x > 2.5 && uniforms.metricOptions.x < 3.5) {
                const float bodyLower = uniforms.metricOptions.y;
                const float bodyUpper = uniforms.metricOptions.z;
                const bool baseIsBody = basePixelValue >= bodyLower && basePixelValue <= bodyUpper;
                if (!baseIsBody) {
                    return;
                }
            }

            const float baseNormalized = metalViewerNormalizedValue(basePixelValue, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
            const float overlayNormalized = metalViewerNormalizedValue(overlayPixelValue, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);

            if (uniforms.metricOptions.x > 1.5 && uniforms.metricOptions.x < 2.5) {
                const float gradientThreshold = uniforms.metricOptions.y;
                const float baseGradient = metalViewerGradientMagnitudeNormalized(baseTexture, metricSampler, baseCoord, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
                const float overlayGradient = metalViewerGradientMagnitudeNormalized(overlayTexture, metricSampler, overlayCoord, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);
                if (max(baseGradient, overlayGradient) < gradientThreshold) {
                    return;
                }
            }

            const uint baseBin = min(uint(baseNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
            const uint overlayBin = min(uint(overlayNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
            const uint histogramIndex = overlayBin * kRegistrationHistogramBins + baseBin;
            atomic_fetch_add_explicit(&jointHistogram[histogramIndex], 1, memory_order_relaxed);
        }
    }
}

kernel void metalViewerRegistrationJointHistogramsBatch(
    texture3d<float, access::sample> baseTexture [[texture(0)]],
    texture3d<float, access::sample> overlayTexture [[texture(1)]],
    constant RegistrationUniforms *candidateUniforms [[buffer(0)]],
    device atomic_uint *jointHistograms [[buffer(1)]],
    constant uint &candidateCount [[buffer(2)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (candidateCount == 0) {
        return;
    }

    constexpr sampler metricSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    const uint baseDepth = max(candidateUniforms[0].baseTextureSize.z, 1u);
    const uint candidateIndex = gid.z / baseDepth;
    if (candidateIndex >= candidateCount) {
        return;
    }

    const RegistrationUniforms uniforms = candidateUniforms[candidateIndex];
    const uint fixedZ = gid.z - candidateIndex * baseDepth;
    if (gid.x >= uniforms.baseTextureSize.x ||
        gid.y >= uniforms.baseTextureSize.y ||
        fixedZ >= uniforms.baseTextureSize.z) {
        return;
    }

    const float3 baseSize = float3(uniforms.baseTextureSize);
    const float3 fixedVoxel3 = float3(float(gid.x), float(gid.y), float(fixedZ));
    const float3 baseCoord = (fixedVoxel3 + 0.5) / baseSize;
    const float4 fixedVoxel = float4(fixedVoxel3, 1.0);
    const float4 worldPoint = uniforms.fixedVoxelToWorld * fixedVoxel;
    const float3 translatedWorldPoint = worldPoint.xyz - uniforms.overlayTranslationWorld;
    const float3 centeredWorldPoint = translatedWorldPoint - uniforms.movingRotationCenterWorld;
    const float4 rotatedWorldPoint = uniforms.movingInverseRotation * float4(centeredWorldPoint, 1.0);
    const float4 movingVoxel = uniforms.movingWorldToVoxel * float4(rotatedWorldPoint.xyz + uniforms.movingRotationCenterWorld, 1.0);
    const float3 overlaySize = float3(overlayTexture.get_width(), overlayTexture.get_height(), overlayTexture.get_depth());
    const float3 overlayCoord = (movingVoxel.xyz + 0.5) / overlaySize;

    if (overlayCoord.x < 0.0 || overlayCoord.x > 1.0 ||
        overlayCoord.y < 0.0 || overlayCoord.y > 1.0 ||
        overlayCoord.z < 0.0 || overlayCoord.z > 1.0) {
        return;
    }

    const float basePixelValue = baseTexture.sample(metricSampler, baseCoord).r;
    const float overlayPixelValue = overlayTexture.sample(metricSampler, overlayCoord).r;

    if (uniforms.metricOptions.x > 0.5 && uniforms.metricOptions.x < 1.5) {
        const float boneLower = uniforms.metricOptions.y;
        const float boneUpper = uniforms.metricOptions.z;
        const bool baseIsBone = basePixelValue >= boneLower && basePixelValue <= boneUpper;
        const bool overlayIsBone = overlayPixelValue >= boneLower && overlayPixelValue <= boneUpper;
        if (!(baseIsBone && overlayIsBone)) {
            return;
        }
    }

    if (uniforms.metricOptions.x > 2.5 && uniforms.metricOptions.x < 3.5) {
        const float bodyLower = uniforms.metricOptions.y;
        const float bodyUpper = uniforms.metricOptions.z;
        const bool baseIsBody = basePixelValue >= bodyLower && basePixelValue <= bodyUpper;
        if (!baseIsBody) {
            return;
        }
    }

    const float baseNormalized = metalViewerNormalizedValue(basePixelValue, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
    const float overlayNormalized = metalViewerNormalizedValue(overlayPixelValue, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);

    if (uniforms.metricOptions.x > 1.5 && uniforms.metricOptions.x < 2.5) {
        const float gradientThreshold = uniforms.metricOptions.y;
        const float baseGradient = metalViewerGradientMagnitudeNormalized(baseTexture, metricSampler, baseCoord, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
        const float overlayGradient = metalViewerGradientMagnitudeNormalized(overlayTexture, metricSampler, overlayCoord, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);
        if (max(baseGradient, overlayGradient) < gradientThreshold) {
            return;
        }
    }

    const uint baseBin = min(uint(baseNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
    const uint overlayBin = min(uint(overlayNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
    const uint histogramIndex = overlayBin * kRegistrationHistogramBins + baseBin;
    const uint histogramOffset = candidateIndex * kRegistrationHistogramBins * kRegistrationHistogramBins;
    atomic_fetch_add_explicit(&jointHistograms[histogramOffset + histogramIndex], 1, memory_order_relaxed);
}

kernel void metalViewerRegistrationSamplingProbe(
    texture3d<float, access::sample> baseTexture [[texture(0)]],
    texture3d<float, access::sample> overlayTexture [[texture(1)]],
    constant RegistrationUniforms &uniforms [[buffer(0)]],
    device uint *threadgroupCounts [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]],
    uint3 threadPosition [[thread_position_in_threadgroup]],
    uint3 threadgroupPosition [[threadgroup_position_in_grid]],
    uint3 threadgroupsPerGrid [[threadgroups_per_grid]]
) {
    threadgroup atomic_uint localCount;
    if (all(threadPosition == uint3(0))) {
        atomic_store_explicit(&localCount, 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    bool accepted = false;
    if (gid.x < uniforms.baseTextureSize.x && gid.y < uniforms.baseTextureSize.y && gid.z < uniforms.baseTextureSize.z) {
        constexpr sampler metricSampler(coord::normalized, address::clamp_to_zero, filter::linear);

        const float3 baseSize = float3(uniforms.baseTextureSize);
        const float3 baseCoord = (float3(gid) + 0.5) / baseSize;
        const float4 fixedVoxel = float4(float3(gid), 1.0);
        const float4 worldPoint = uniforms.fixedVoxelToWorld * fixedVoxel;
        const float3 translatedWorldPoint = worldPoint.xyz - uniforms.overlayTranslationWorld;
        const float3 centeredWorldPoint = translatedWorldPoint - uniforms.movingRotationCenterWorld;
        const float4 rotatedWorldPoint = uniforms.movingInverseRotation * float4(centeredWorldPoint, 1.0);
        const float4 movingVoxel = uniforms.movingWorldToVoxel * float4(rotatedWorldPoint.xyz + uniforms.movingRotationCenterWorld, 1.0);
        const float3 overlaySize = float3(overlayTexture.get_width(), overlayTexture.get_height(), overlayTexture.get_depth());
        const float3 overlayCoord = (movingVoxel.xyz + 0.5) / overlaySize;

        if (overlayCoord.x >= 0.0 && overlayCoord.x <= 1.0 &&
            overlayCoord.y >= 0.0 && overlayCoord.y <= 1.0 &&
            overlayCoord.z >= 0.0 && overlayCoord.z <= 1.0) {
            const float basePixelValue = baseTexture.sample(metricSampler, baseCoord).r;
            const float overlayPixelValue = overlayTexture.sample(metricSampler, overlayCoord).r;
            accepted = true;

            if (uniforms.metricOptions.x > 0.5 && uniforms.metricOptions.x < 1.5) {
                const float boneLower = uniforms.metricOptions.y;
                const float boneUpper = uniforms.metricOptions.z;
                const bool baseIsBone = basePixelValue >= boneLower && basePixelValue <= boneUpper;
                const bool overlayIsBone = overlayPixelValue >= boneLower && overlayPixelValue <= boneUpper;
                if (!(baseIsBone && overlayIsBone)) {
                    accepted = false;
                }
            }

            if (accepted && uniforms.metricOptions.x > 2.5 && uniforms.metricOptions.x < 3.5) {
                const float bodyLower = uniforms.metricOptions.y;
                const float bodyUpper = uniforms.metricOptions.z;
                const bool baseIsBody = basePixelValue >= bodyLower && basePixelValue <= bodyUpper;
                if (!baseIsBody) {
                    accepted = false;
                }
            }

            if (accepted && uniforms.metricOptions.x > 1.5 && uniforms.metricOptions.x < 2.5) {
                const float gradientThreshold = uniforms.metricOptions.y;
                const float baseGradient = metalViewerGradientMagnitudeNormalized(baseTexture, metricSampler, baseCoord, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
                const float overlayGradient = metalViewerGradientMagnitudeNormalized(overlayTexture, metricSampler, overlayCoord, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);
                if (max(baseGradient, overlayGradient) < gradientThreshold) {
                    accepted = false;
                }
            }

            if (accepted) {
                atomic_fetch_add_explicit(&localCount, 1, memory_order_relaxed);
            }
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (all(threadPosition == uint3(0))) {
        const uint index = (threadgroupPosition.z * threadgroupsPerGrid.y + threadgroupPosition.y) * threadgroupsPerGrid.x + threadgroupPosition.x;
        threadgroupCounts[index] = atomic_load_explicit(&localCount, memory_order_relaxed);
    }
}

kernel void metalViewerConvertStoredSigned3D(
    texture3d<int, access::read> sourceTexture [[texture(0)]],
    texture3d<float, access::write> destinationTexture [[texture(1)]],
    constant StoredVolumeConversionUniforms &uniforms [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.sourceSize.xyz)) {
        return;
    }
    const float value = float(sourceTexture.read(gid).r) * uniforms.rescale.x + uniforms.rescale.y;
    destinationTexture.write(float4(value), gid);
}

kernel void metalViewerConvertStoredUnsigned3D(
    texture3d<uint, access::read> sourceTexture [[texture(0)]],
    texture3d<float, access::write> destinationTexture [[texture(1)]],
    constant StoredVolumeConversionUniforms &uniforms [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.sourceSize.xyz)) {
        return;
    }
    const float value = float(sourceTexture.read(gid).r) * uniforms.rescale.x + uniforms.rescale.y;
    destinationTexture.write(float4(value), gid);
}

kernel void metal3DHistogram(
    texture3d<float, access::read> sourceTexture [[texture(0)]],
    device atomic_uint *histogram [[buffer(0)]],
    constant Metal3DHistogramUniforms &uniforms [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.sourceSize.xyz) || uniforms.binCount == 0u) {
        return;
    }

    const float value = sourceTexture.read(gid).r;
    if (!isfinite(value)) {
        return;
    }

    const float span = max(uniforms.domain.y - uniforms.domain.x, 1.0e-5f);
    const float normalized = clamp((value - uniforms.domain.x) / span, 0.0f, 1.0f);
    const uint bin = min(uint(normalized * float(uniforms.binCount - 1u)), uniforms.binCount - 1u);
    atomic_fetch_add_explicit(&histogram[bin], 1u, memory_order_relaxed);
}

kernel void metalViewerGaussianBlur3D(
    texture3d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::write> destinationTexture [[texture(1)]],
    constant GaussianBlurUniforms &uniforms [[buffer(0)]],
    constant float *kernelWeights [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.sourceSize.x || gid.y >= uniforms.sourceSize.y || gid.z >= uniforms.sourceSize.z) {
        return;
    }

    float sum = 0.0;
    const int radius = int(uniforms.radius);
    for (int kernelIndex = -radius; kernelIndex <= radius; ++kernelIndex) {
        int3 sample = int3(gid);
        if (uniforms.axis == 0) {
            sample.x = clamp(sample.x + kernelIndex, 0, int(uniforms.sourceSize.x) - 1);
        } else if (uniforms.axis == 1) {
            sample.y = clamp(sample.y + kernelIndex, 0, int(uniforms.sourceSize.y) - 1);
        } else {
            sample.z = clamp(sample.z + kernelIndex, 0, int(uniforms.sourceSize.z) - 1);
        }

        sum += sourceTexture.read(uint3(sample)).r * kernelWeights[kernelIndex + radius];
    }

    destinationTexture.write(float4(sum), gid);
}

kernel void metalViewerDownsample3D(
    texture3d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::write> destinationTexture [[texture(1)]],
    constant DownsampleUniforms &uniforms [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height() || gid.z >= destinationTexture.get_depth()) {
        return;
    }

    const uint factor = max(uniforms.factor, 1u);
    const uint3 start = gid * factor;
    const uint3 end = min(start + uint3(factor, factor, factor), uniforms.sourceSize);

    float sum = 0.0;
    uint count = 0;
    for (uint z = start.z; z < end.z; ++z) {
        for (uint y = start.y; y < end.y; ++y) {
            for (uint x = start.x; x < end.x; ++x) {
                sum += sourceTexture.read(uint3(x, y, z)).r;
                count += 1;
            }
        }
    }

    destinationTexture.write(float4(count > 0 ? sum / float(count) : 0.0), gid);
}

kernel void metalViewerGantryTiltResample3D(
    texture3d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::write> destinationTexture [[texture(1)]],
    constant GantryTiltResampleUniforms &uniforms [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.outputSize.x || gid.y >= uniforms.outputSize.y || gid.z >= uniforms.outputSize.z) {
        return;
    }

    constexpr sampler volumeSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    const float3 sourceSize = float3(
        sourceTexture.get_width(),
        sourceTexture.get_height(),
        sourceTexture.get_depth()
    );
    const float4 outputVoxel = float4(float3(gid), 1.0);
    const float4 world = uniforms.outputVoxelToWorld * outputVoxel;
    const float4 sourceVoxel = uniforms.sourceWorldToVoxel * world;
    const bool inside = sourceVoxel.x >= 0.0 &&
        sourceVoxel.y >= 0.0 &&
        sourceVoxel.z >= 0.0 &&
        sourceVoxel.x <= sourceSize.x - 1.0 &&
        sourceVoxel.y <= sourceSize.y - 1.0 &&
        sourceVoxel.z <= sourceSize.z - 1.0;
    float value = uniforms.backgroundValue.x;

    if (inside) {
        const float3 sampleCoordinate = (sourceVoxel.xyz + 0.5) / sourceSize;
        value = sourceTexture.sample(volumeSampler, sampleCoordinate).r;
    }

    destinationTexture.write(float4(value), gid);
}
