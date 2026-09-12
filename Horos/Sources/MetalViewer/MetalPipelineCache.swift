import Foundation
import Metal

// Only immutable shader resources are shared. Queues, textures, buffers, and
// per-view state remain owned by their renderer or processing job.
final class MetalPipelineCache {
    private struct RenderKey: Hashable {
        let vertex: String
        let fragment: String
        let colorPixelFormat: MTLPixelFormat
        let depthPixelFormat: MTLPixelFormat
        let sampleCount: Int
        let alphaBlending: Bool
    }

    private enum CacheError: Error {
        case missingDefaultLibrary
        case missingFunction(String)
    }

    private static let devicesLock = NSLock()
    private static var devices: [UInt64: MetalPipelineCache] = [:]

    static func shared(for device: MTLDevice) throws -> MetalPipelineCache {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        if let cache = devices[device.registryID] {
            return cache
        }
        let cache = try MetalPipelineCache(device: device)
        devices[device.registryID] = cache
        return cache
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let lock = NSLock()
    private var renderPipelines: [RenderKey: MTLRenderPipelineState] = [:]
    private var computePipelines: [String: MTLComputePipelineState] = [:]

    private init(device: MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw CacheError.missingDefaultLibrary
        }
        self.device = device
        self.library = library
    }

    func renderPipeline(
        vertex: String,
        fragment: String,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        depthPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1,
        alphaBlending: Bool = false,
        label: String? = nil
    ) throws -> MTLRenderPipelineState {
        let key = RenderKey(
            vertex: vertex,
            fragment: fragment,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            sampleCount: sampleCount,
            alphaBlending: alphaBlending
        )
        lock.lock()
        defer { lock.unlock() }
        if let pipeline = renderPipelines[key] {
            return pipeline
        }

        // Keep creation under the lock so concurrent viewers cannot compile
        // the same pipeline twice. Failed creations are not cached.
        let descriptor = MTLRenderPipelineDescriptor()
        // Metal validation rejects setting a nil label; leave the default untouched.
        if let label {
            descriptor.label = label
        }
        descriptor.vertexFunction = try function(named: vertex)
        descriptor.fragmentFunction = try function(named: fragment)
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        descriptor.rasterSampleCount = sampleCount
        if alphaBlending {
            let attachment: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.rgbBlendOperation = .add
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            attachment.alphaBlendOperation = .add
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        renderPipelines[key] = pipeline
        return pipeline
    }

    func computePipeline(function name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let pipeline = computePipelines[name] {
            return pipeline
        }
        let pipeline = try device.makeComputePipelineState(function: function(named: name))
        computePipelines[name] = pipeline
        return pipeline
    }

    private func function(named name: String) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw CacheError.missingFunction(name)
        }
        return function
    }
}
