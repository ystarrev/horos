import simd

struct MetalViewerSurfaceVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

/// Patient-space geometry shared by ROI display and Frame planning.
struct MetalViewerSceneSurface {
    let vertices: [MetalViewerSurfaceVertex]
    var canonicalToCurrentTransform = matrix_identity_float4x4
    let color: SIMD3<Float>
}

typealias MetalStudyROISurfaceVertex = MetalViewerSurfaceVertex

/// Patient-space one-pixel lines, independent of the scene's physical zoom.
struct MetalViewerSceneLine {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let color: SIMD3<Float>
}
