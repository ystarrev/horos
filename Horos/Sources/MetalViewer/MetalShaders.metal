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
    float windowLevel;
    float windowWidth;
    float shading;
    uint hasCLUT;
};

struct Metal3DRasterizerData {
    float4 position [[position]];
    float2 uv;
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

vertex Metal3DRasterizerData metal3DVolumeVertex(
    const device Metal3DVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]]
) {
    Metal3DRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.uv = vertices[vertexID].uv;
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
    float normalizedScalar,
    texture2d<float> opacityTexture,
    sampler transferSampler
) {
    return opacityTexture.sample(transferSampler, float2(clamp(normalizedScalar, 0.0, 1.0), 0.5)).r;
}

static inline float3 metal3DColorAt(
    float normalizedScalar,
    texture2d<float> clutTexture,
    sampler transferSampler
) {
    return clutTexture.sample(transferSampler, float2(clamp(normalizedScalar, 0.0, 1.0), 0.5)).rgb;
}

static inline float3 metal3DGradient(
    float3 texCoord,
    texture3d<float> volumeTexture,
    sampler volumeSampler,
    uint3 dimensions
) {
    float3 delta = 1.0 / max(float3(dimensions - uint3(1)), float3(1.0));
    float sampleX1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleX0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleY1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleY0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleZ1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    float sampleZ0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    return float3(sampleX1 - sampleX0, sampleY1 - sampleY0, sampleZ1 - sampleZ0);
}

fragment float4 metal3DVolumeFragment(
    Metal3DRasterizerData in [[stage_in]],
    constant Metal3DVolumeUniforms &uniforms [[buffer(0)]],
    texture3d<float> volumeTexture [[texture(0)]],
    texture2d<float> clutTexture [[texture(1)]],
    texture2d<float> opacityTexture [[texture(2)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, in.uv.y * 2.0 - 1.0);
    float3 rayDirection = normalize(
        uniforms.cameraForward +
        ndc.x * uniforms.aspectRatio * uniforms.tanHalfFovY * uniforms.cameraRight +
        ndc.y * uniforms.tanHalfFovY * uniforms.cameraUp
    );

    float3 marchingBoxMin = uniforms.cropEnabled != 0 ? max(uniforms.boxMin, uniforms.cropBoxMin) : uniforms.boxMin;
    float3 marchingBoxMax = uniforms.cropEnabled != 0 ? min(uniforms.boxMax, uniforms.cropBoxMax) : uniforms.boxMax;

    float tMin = 0.0;
    float tMax = 0.0;
    if (!metal3DIntersectBox(uniforms.cameraPosition, rayDirection, marchingBoxMin, marchingBoxMax, tMin, tMax)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    const float3 lightDirection = normalize(float3(0.45, 0.5, 1.0));
    float4 accumulated = float4(0.0);
    float t = max(tMin, 0.0);

    for (uint stepIndex = 0; stepIndex < 1024 && t <= tMax && accumulated.a < 0.985; ++stepIndex, t += uniforms.stepSize) {
        float3 position = uniforms.cameraPosition + rayDirection * t;
        float3 texCoord = metal3DTextureCoordinate(position, uniforms.boxMin, uniforms.boxMax);

        if (any(texCoord < 0.0) || any(texCoord > 1.0)) {
            continue;
        }

        float normalizedScalar = volumeTexture.sample(textureSampler, texCoord).r;
        float opacity = metal3DOpacityAt(normalizedScalar, opacityTexture, textureSampler);
        if (opacity <= 0.001) {
            continue;
        }

        float3 color = metal3DColorAt(normalizedScalar, clutTexture, textureSampler);
        if (uniforms.shading > 0.5) {
            float3 gradient = metal3DGradient(texCoord, volumeTexture, textureSampler, uniforms.volumeDimensions);
            float gradientLength = length(gradient);
            if (gradientLength > 1e-5) {
                float3 normal = normalize(gradient);
                float diffuse = max(dot(normal, lightDirection), 0.0);
                float ambient = 0.35;
                color *= ambient + (1.0 - ambient) * diffuse;
            }
        }

        float sampleAlpha = 1.0 - exp(-clamp(opacity, 0.0, 1.0) * uniforms.density * uniforms.stepSize * 80.0);
        accumulated.rgb += (1.0 - accumulated.a) * sampleAlpha * color;
        accumulated.a += (1.0 - accumulated.a) * sampleAlpha;
    }

    float3 finalColor = accumulated.rgb;
    return float4(finalColor, 1.0);
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
