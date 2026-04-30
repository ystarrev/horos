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

struct MetalMPRVertex {
    float3 position;
    float3 baseVoxel;
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
};

struct MetalPreviewUniforms {
    float2 scale;
    float2 offset;
    float windowLevel;
    float windowWidth;
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

struct RasterizerData {
    float4 position [[position]];
    float2 texCoord;
};

struct MetalMPRRasterizerData {
    float4 position [[position]];
    float3 baseVoxel;
};

struct MetalMPRBorderRasterizerData {
    float4 position [[position]];
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
    uint maxSteps;
    float windowLevel;
    float windowWidth;
    float4 boneRenderingOptions;
    float opacityDomainMin;
    float opacityDomainMax;
    uint useRawOpacityCurve;
    uint padding4;
    float shading;
    float ambient;
    float diffuse;
    float specular;
    float specularPower;
    uint hasCLUT;
    float4x4 viewProjectionMatrix;
};

struct Metal3DRasterizerData {
    float4 position [[position]];
    float2 uv;
};

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
    float2 scaledPosition = vertices[vertexID].position * uniforms.scale + uniforms.offset;
    out.position = float4(scaledPosition, 0.0, 1.0);
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
    return out;
}

vertex MetalMPRBorderRasterizerData metalViewerMPRBorderVertex(
    const device MetalMPRVertex *vertices [[buffer(0)]],
    constant MetalMPRUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    MetalMPRBorderRasterizerData out;
    out.position = uniforms.viewProjectionMatrix * float4(vertices[vertexID].position, 1.0);
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
    uint3 dimensions
) {
    float3 delta = 1.5 / max(float3(dimensions - uint3(1)), float3(1.0));
    float sampleX1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleX0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(delta.x, 0.0, 0.0), 0.0, 1.0)).r;
    float sampleY1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleY0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, delta.y, 0.0), 0.0, 1.0)).r;
    float sampleZ1 = volumeTexture.sample(volumeSampler, clamp(texCoord + float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    float sampleZ0 = volumeTexture.sample(volumeSampler, clamp(texCoord - float3(0.0, 0.0, delta.z), 0.0, 1.0)).r;
    return float3(sampleX1 - sampleX0, sampleY1 - sampleY0, sampleZ1 - sampleZ0);
}

fragment Metal3DFragmentOutput metal3DVolumeFragment(
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
        Metal3DFragmentOutput output;
        output.color = float4(0.0, 0.0, 0.0, 1.0);
        output.depth = 1.0;
        return output;
    }

    float4 accumulated = float4(0.0);
    float t = max(tMin, 0.0);
    float previousScalar = 0.0;
    float previousT = t;
    bool havePreviousScalar = false;

    for (uint stepIndex = 0; stepIndex < uniforms.maxSteps && t <= tMax && accumulated.a < 0.985; ++stepIndex, t += uniforms.stepSize) {
        float3 position = uniforms.cameraPosition + rayDirection * t;
        float3 texCoord = metal3DTextureCoordinate(position, uniforms.boxMin, uniforms.boxMax);

        if (any(texCoord < 0.0) || any(texCoord > 1.0)) {
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
                float3 refinedPosition = uniforms.cameraPosition + rayDirection * refinedMid;
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
            float3 hitPosition = uniforms.cameraPosition + rayDirection * hitT;
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
                float3 gradient = metal3DGradient(hitCoord, volumeTexture, textureSampler, uniforms.volumeDimensions);
                float gradientLength = length(gradient);
                if (gradientLength > 1e-5) {
                    float3 normal = normalize(gradient);
                    float3 viewDirection = normalize(uniforms.cameraPosition - hitPosition);
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
            opacity = metal3DOpacityAt(scalar, uniforms.windowLevel, uniforms.windowWidth, opacityTexture, textureSampler);
            if (opacity <= 0.03) {
                previousScalar = scalar;
                previousT = t;
                havePreviousScalar = true;
                continue;
            }
            color = metal3DColorAt(scalar, uniforms.windowLevel, uniforms.windowWidth, clutTexture, textureSampler);
            previousScalar = scalar;
            previousT = t;
            havePreviousScalar = true;
        }
        if (uniforms.shading > 0.5) {
            float3 gradient = metal3DGradient(texCoord, volumeTexture, textureSampler, uniforms.volumeDimensions);
            float gradientLength = length(gradient);
            if (gradientLength > 1e-5) {
                float3 normal = normalize(gradient);
                float3 viewDirection = normalize(uniforms.cameraPosition - position);
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
                color += uniforms.specular * specular * spotFactor;
            }
        }

        float sampleAlpha = 1.0 - exp(-clamp(opacity, 0.0, 1.0) * uniforms.density * uniforms.stepSize);
        if (sampleAlpha <= 0.0025) {
            continue;
        }
        accumulated.rgb += (1.0 - accumulated.a) * sampleAlpha * color;
        accumulated.a += (1.0 - accumulated.a) * sampleAlpha;
    }

    if (accumulated.a < uniforms.alphaFloor) {
        Metal3DFragmentOutput output;
        output.color = float4(0.0, 0.0, 0.0, 1.0);
        output.depth = 1.0;
        return output;
    }

    float3 finalColor = accumulated.rgb;
    Metal3DFragmentOutput output;
    output.color = float4(finalColor, 1.0);
    output.depth = 0.9999;
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

fragment float4 metalViewerMPRFragment(
    MetalMPRRasterizerData in [[stage_in]],
    constant MetalMPRUniforms &uniforms [[buffer(0)]],
    texture3d<float> baseTexture [[texture(0)]],
    texture3d<float> overlayTexture [[texture(1)]],
    sampler imageSampler [[sampler(0)]]
) {
    const float3 baseSize = float3(baseTexture.get_width(), baseTexture.get_height(), baseTexture.get_depth());
    const float3 baseCoord = (in.baseVoxel + 0.5) / baseSize;

    if (baseCoord.x < 0.0 || baseCoord.x > 1.0 ||
        baseCoord.y < 0.0 || baseCoord.y > 1.0 ||
        baseCoord.z < 0.0 || baseCoord.z > 1.0) {
        discard_fragment();
    }

    const float basePixelValue = baseTexture.sample(imageSampler, baseCoord).r;
    const float baseMinValue = uniforms.baseWindowLevel - uniforms.baseWindowWidth * 0.5;
    const float baseNormalized = clamp((basePixelValue - baseMinValue) / uniforms.baseWindowWidth, 0.0, 1.0);

    if (uniforms.hasOverlay == 0) {
        return float4(baseNormalized, baseNormalized, baseNormalized, 1.0);
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
        return float4(0.0, baseNormalized, 0.0, 1.0);
    }

    const float overlayPixelValue = overlayTexture.sample(imageSampler, overlayCoord).r;
    const float overlayMinValue = uniforms.overlayWindowLevel - uniforms.overlayWindowWidth * 0.5;
    const float overlayNormalized = clamp((overlayPixelValue - overlayMinValue) / uniforms.overlayWindowWidth, 0.0, 1.0);

    return float4(overlayNormalized * uniforms.overlayBlend, baseNormalized * (1.0 - uniforms.overlayBlend), 0.0, 1.0);
}

fragment float4 metalViewerMPRBorderFragment(
    MetalMPRBorderRasterizerData in [[stage_in]]
) {
    return float4(0.18, 1.0, 0.28, 1.0);
}

fragment float4 metalViewerMPRIntersectionFragment(
    MetalMPRBorderRasterizerData in [[stage_in]]
) {
    return float4(1.0, 0.0, 0.0, 1.0);
}

fragment float4 metalViewerMPRPlaneHighlightFragment(
    MetalMPRRasterizerData in [[stage_in]]
) {
    return float4(1.0, 0.0, 0.0, 1.0);
}

fragment float4 metalPreviewFragment(
    RasterizerData in [[stage_in]],
    constant MetalPreviewUniforms &uniforms [[buffer(0)]],
    texture2d<float> imageTexture [[texture(0)]],
    sampler imageSampler [[sampler(0)]]
) {
    float pixelValue = imageTexture.sample(imageSampler, in.texCoord).r;
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
                const float baseNormalized = metalViewerNormalizedValue(basePixelValue, uniforms.baseWindowLevel, uniforms.baseWindowWidth);
                const float overlayNormalized = metalViewerNormalizedValue(overlayPixelValue, uniforms.overlayWindowLevel, uniforms.overlayWindowWidth);
                const uint baseBin = min(uint(baseNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
                const uint overlayBin = min(uint(overlayNormalized * float(kRegistrationHistogramBins - 1)), kRegistrationHistogramBins - 1);
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
