#include <metal_stdlib>
using namespace metal;

constant uint kRegistrationHistogramBins = 64;

struct MetalVertex {
    float2 position;
    float2 texCoord;
};

struct MetalUniforms {
    float2 scale;
    float2 offset;
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
};

struct RegistrationUniforms {
    float baseWindowLevel;
    float baseWindowWidth;
    float overlayWindowLevel;
    float overlayWindowWidth;
    float4 registrationOptions;
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

struct RasterizerData {
    float4 position [[position]];
    float2 texCoord;
};

vertex RasterizerData metalViewerVertex(
    const device MetalVertex *vertices [[buffer(0)]],
    constant MetalUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    RasterizerData out;
    float2 scaledPosition = vertices[vertexID].position * uniforms.scale + uniforms.offset;
    out.position = float4(scaledPosition, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

fragment float4 metalViewerFragment(
    RasterizerData in [[stage_in]],
    constant MetalUniforms &uniforms [[buffer(0)]],
    texture2d<float> baseTexture [[texture(0)]],
    texture3d<float> overlayTexture [[texture(1)]],
    sampler imageSampler [[sampler(0)]]
) {
    const float basePixelValue = baseTexture.sample(imageSampler, in.texCoord).r;
    const float baseMinValue = uniforms.baseWindowLevel - uniforms.baseWindowWidth * 0.5;
    const float baseNormalized = clamp((basePixelValue - baseMinValue) / uniforms.baseWindowWidth, 0.0, 1.0);

    if (uniforms.hasOverlay == 0) {
        return float4(baseNormalized, baseNormalized, baseNormalized, 1.0);
    }

    const float x = in.texCoord.x * max(float(uniforms.fixedVolumeSize.x) - 1.0, 0.0);
    const float y = in.texCoord.y * max(float(uniforms.fixedVolumeSize.y) - 1.0, 0.0);
    const float z = uniforms.currentSliceIndex;

    const float4 fixedVoxel = float4(x, y, z, 1.0);
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
        return float4(0.0, baseNormalized * (1.0 - uniforms.overlayBlend), 0.0, 1.0);
    }

    const float overlayPixelValue = overlayTexture.sample(imageSampler, overlayCoord).r;
    const float overlayMinValue = uniforms.overlayWindowLevel - uniforms.overlayWindowWidth * 0.5;
    const float overlayNormalized = clamp((overlayPixelValue - overlayMinValue) / uniforms.overlayWindowWidth, 0.0, 1.0);

    return float4(overlayNormalized * uniforms.overlayBlend, baseNormalized * (1.0 - uniforms.overlayBlend), 0.0, 1.0);
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

            if (uniforms.registrationOptions.x > 0.5) {
                const float boneLower = uniforms.registrationOptions.y;
                const float boneUpper = uniforms.registrationOptions.z;
                const bool baseIsBone = basePixelValue >= boneLower && basePixelValue <= boneUpper;
                const bool overlayIsBone = overlayPixelValue >= boneLower && overlayPixelValue <= boneUpper;
                if (!(baseIsBone && overlayIsBone)) {
                    return;
                }
            }

            const float baseMinValue = uniforms.baseWindowLevel - uniforms.baseWindowWidth * 0.5;
            const float overlayMinValue = uniforms.overlayWindowLevel - uniforms.overlayWindowWidth * 0.5;

            const float baseNormalized = clamp((basePixelValue - baseMinValue) / uniforms.baseWindowWidth, 0.0, 1.0);
            const float overlayNormalized = clamp((overlayPixelValue - overlayMinValue) / uniforms.overlayWindowWidth, 0.0, 1.0);
            const uint baseBin = min(uint(baseNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
            const uint overlayBin = min(uint(overlayNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
            const uint histogramIndex = overlayBin * kRegistrationHistogramBins + baseBin;
            atomic_fetch_add_explicit(&jointHistogram[histogramIndex], 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&jointHistogram[kRegistrationHistogramBins * kRegistrationHistogramBins], 1, memory_order_relaxed);
        }
    }
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
