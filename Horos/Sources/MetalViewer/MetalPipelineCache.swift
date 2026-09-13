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

    private let compiler: MTL4Compiler
    private let library: MTLLibrary
    private let functionNames: Set<String>
    private let lock = NSLock()
    private var renderPipelines: [RenderKey: MTLRenderPipelineState] = [:]
    private var computePipelines: [String: MTLComputePipelineState] = [:]

    private init(device: MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw CacheError.missingDefaultLibrary
        }
        compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        self.library = library
        functionNames = Set(library.functionNames)
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
        let startedAt = MetalPerformanceTrace.begin()
        let descriptor = MTL4RenderPipelineDescriptor()
        // Metal validation rejects setting a nil label; leave the default untouched.
        if let label {
            descriptor.label = label
        }
        descriptor.vertexFunctionDescriptor = try functionDescriptor(named: vertex)
        descriptor.fragmentFunctionDescriptor = try functionDescriptor(named: fragment)
        let attachment = MTL4RenderPipelineColorAttachmentDescriptor()
        attachment.pixelFormat = colorPixelFormat
        // Metal 4 takes depth/stencil formats from the render pass attachments.
        // Keep depth in the cache key and leave the renderers' depth state unchanged.
        descriptor.rasterSampleCount = sampleCount
        if alphaBlending {
            attachment.blendingState = .enabled
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.rgbBlendOperation = .add
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            attachment.alphaBlendOperation = .add
        }
        descriptor.colorAttachments[0] = attachment
        let pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
        renderPipelines[key] = pipeline
        MetalPerformanceTrace.end("compile.render.\(vertex).\(fragment)", since: startedAt)
        return pipeline
    }

    func computePipeline(function name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let pipeline = computePipelines[name] {
            return pipeline
        }
        let startedAt = MetalPerformanceTrace.begin()
        let descriptor = MTL4ComputePipelineDescriptor()
        descriptor.computeFunctionDescriptor = try functionDescriptor(named: name)
        let pipeline = try compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: nil)
        computePipelines[name] = pipeline
        MetalPerformanceTrace.end("compile.compute.\(name)", since: startedAt)
        return pipeline
    }

    private func functionDescriptor(named name: String) throws -> MTL4LibraryFunctionDescriptor {
        guard functionNames.contains(name) else {
            throw CacheError.missingFunction(name)
        }
        let descriptor = MTL4LibraryFunctionDescriptor()
        descriptor.name = name
        descriptor.library = library
        return descriptor
    }
}
