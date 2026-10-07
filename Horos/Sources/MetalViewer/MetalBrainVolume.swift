import Metal
import simd

/// Immutable GPU volume prepared off-main. The mesh is a stencil, never a shell.
final class MetalBrainVolume {
    let texture: MTLTexture
    let voxelToPatient: simd_float4x4
    let spacing: SIMD3<Float>
    let displayRange: SIMD2<Float>

    init(_ volume: MRIBrainMaskedVolume, device: MTLDevice) throws {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rg32Float
        descriptor.width = volume.dimensions.x
        descriptor.height = volume.dimensions.y
        descriptor.depth = volume.dimensions.z
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MRIBrainExtractionError.invalid("Not enough GPU memory for the clipped brain volume.")
        }
        volume.samples.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, descriptor.width, descriptor.height, descriptor.depth),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: descriptor.width * 8, bytesPerImage: descriptor.width * descriptor.height * 8)
        }
        self.texture = texture
        spacing = SIMD3<Float>(volume.spacing)
        displayRange = volume.displayRange
        voxelToPatient = simd_float4x4(columns: (
            SIMD4(SIMD3<Float>(volume.axes.columns.0 * volume.spacing.x), 0),
            SIMD4(SIMD3<Float>(volume.axes.columns.1 * volume.spacing.y), 0),
            SIMD4(SIMD3<Float>(volume.axes.columns.2 * volume.spacing.z), 0),
            SIMD4(SIMD3<Float>(volume.originLPS), 1)))
    }
}

struct MetalBrainClipPlane {
    var origin: SIMD4<Float>
    var u: SIMD4<Float>
    var v: SIMD4<Float>
}

struct MetalBrainVolumeUniforms {
    var clipToVoxel: simd_float4x4
    var voxelToClip: simd_float4x4
    var dimensions: SIMD4<Float>
    var spacingAndStep: SIMD4<Float>
    var range: SIMD4<Float>
    var axial: MetalBrainClipPlane
    var coronal: MetalBrainClipPlane
    var sagittal: MetalBrainClipPlane
}
