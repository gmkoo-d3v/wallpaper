import CoreGraphics
import Foundation
import ImageIO
import Metal

enum MetalSnapshotImage {
    static func makeRenderTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EngineError.renderer("Could not allocate snapshot render texture")
        }
        return texture
    }

    static func readImage(
        texture: MTLTexture,
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer
    ) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let sourceBytesPerRow = width * 4
        let destinationBytesPerRow = ((sourceBytesPerRow + 255) / 256) * 256
        let destinationLength = destinationBytesPerRow * height
        guard let readBuffer = device.makeBuffer(length: destinationLength, options: [.storageModeShared]),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw EngineError.renderer("Could not allocate snapshot readback buffer")
        }
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: destinationBytesPerRow,
            destinationBytesPerImage: destinationLength
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw EngineError.renderer("Snapshot render failed: \(error.localizedDescription)")
        }

        var pixels = [UInt8](repeating: 0, count: sourceBytesPerRow * height)
        let sourcePointer = readBuffer.contents().assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return }
            for row in 0..<height {
                baseAddress
                    .advanced(by: row * sourceBytesPerRow)
                    .copyMemory(
                        from: sourcePointer.advanced(by: row * destinationBytesPerRow),
                        byteCount: sourceBytesPerRow
                    )
            }
        }
        return try imageFromBGRA(pixels: pixels, width: width, height: height)
    }

    static func writePNG(_ image: CGImage, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destinationWriter = CGImageDestinationCreateWithURL(
            destination as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw EngineError.renderer("Could not create PNG writer for \(destination.path)")
        }
        CGImageDestinationAddImage(destinationWriter, image, nil)
        guard CGImageDestinationFinalize(destinationWriter) else {
            throw EngineError.renderer("Could not write snapshot PNG: \(destination.path)")
        }
    }

    static func loadImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EngineError.asset("Could not read PNG image: \(url.path)")
        }
        return image
    }

    static func bgraPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw EngineError.renderer("Could not create image diff bitmap context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func imageFromBGRA(pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw EngineError.renderer("Could not create snapshot image provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw EngineError.renderer("Could not create snapshot CGImage")
        }
        return image
    }
}
