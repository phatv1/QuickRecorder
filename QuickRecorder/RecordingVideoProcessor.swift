import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import CoreGraphics
import ScreenCaptureKit
import CryptoKit

/// Source-proportional capture uses ScreenCaptureKit's scaler. Only padding, cropping,
/// stretching or grayscale needs a second GPU pass; ordinary recordings pass through.
enum RecordingVideoProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let poolLock = NSLock()
    private static var pool: CVPixelBufferPool?
    private static var poolKey = ""

    static func outputSize(sourceSize: CGSize, options: RecordingOptions) throws -> CGSize {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 2, sourceSize.height >= 2,
              sourceSize.width <= 32768, sourceSize.height <= 32768 else {
            throw RecordingOptionsError.invalid(["The capture source has invalid dimensions."])
        }
        let size = try options.outputSize(sourceWidth: Int(sourceSize.width), sourceHeight: Int(sourceSize.height))
        return CGSize(width: size.width, height: size.height)
    }

    static func captureSize(sourceSize: CGSize, options: RecordingOptions) throws -> CGSize {
        let canvas = try outputSize(sourceSize: sourceSize, options: options)
        guard options.resolutionMode == "custom" else { return canvas }
        let scaleX = canvas.width / sourceSize.width
        let scaleY = canvas.height / sourceSize.height
        var scale = options.scalingMode == "fit" ? min(scaleX, scaleY) : max(scaleX, scaleY)
        if !options.allowUpscaling { scale = min(scale, 1) }
        let width = max(2, (sourceSize.width * scale / 2).rounded(.up) * 2)
        let height = max(2, (sourceSize.height * scale / 2).rounded(.up) * 2)
        guard width <= 32768, height <= 32768 else {
            throw RecordingOptionsError.invalid(["This aspect ratio requires an excessively large capture surface. Use Fit or reduce the canvas size."])
        }
        return CGSize(width: width, height: height)
    }

    static func prepare(sample: CMSampleBuffer, options: RecordingOptions, outputSize: CGSize) -> CMSampleBuffer? {
        guard let source = sample.imageBuffer else { return nil }
        let width = Int(outputSize.width), height = Int(outputSize.height)
        guard width > 0, height > 0 else { return nil }
        if !options.grayscale && CVPixelBufferGetWidth(source) == width && CVPixelBufferGetHeight(source) == height {
            return sample
        }

        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        let isHighDepth = sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || sourceFormat == kCVPixelFormatType_64RGBAHalf
        let format = isHighDepth ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        guard let destination = pixelBuffer(width: width, height: height, format: format) else { return nil }

        var image = CIImage(cvPixelBuffer: source)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var sx = CGFloat(width) / image.extent.width
        var sy = CGFloat(height) / image.extent.height
        if options.scalingMode != "stretch" {
            let scale = options.scalingMode == "fill" ? max(sx, sy) : min(sx, sy)
            sx = scale; sy = scale
        }
        if !options.allowUpscaling { sx = min(sx, 1); sy = min(sy, 1) }
        image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        image = image.transformed(by: CGAffineTransform(translationX: (CGFloat(width) - image.extent.width) / 2,
                                                      y: (CGFloat(height) - image.extent.height) / 2))
        if options.grayscale { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0]) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        image = image.composited(over: background).cropped(to: bounds)
        let colorSpace = CGColorSpace(name: isHighDepth ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB)
        context.render(image, to: destination, bounds: bounds, colorSpace: colorSpace)
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
        return sampleBuffer(imageBuffer: destination, timingFrom: sample)
    }

    /// Copies pixels out of ScreenCaptureKit's IOSurface pool, allowing capture to recycle it.
    /// Used only for the held terminal frame, never an unbounded frame history.
    static func independentCopy(of sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = sample.imageBuffer else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(source),
                                  attributes as CFDictionary, &result) == kCVReturnSuccess,
              let destination = result else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                    memcpy(dst.advanced(by: row * destinationStride), src.advanced(by: row * sourceStride), min(sourceStride, destinationStride))
                }
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let sourceStride = CVPixelBufferGetBytesPerRow(source), destinationStride = CVPixelBufferGetBytesPerRow(destination)
            for row in 0..<height {
                memcpy(dst.advanced(by: row * destinationStride), src.advanced(by: row * sourceStride), min(sourceStride, destinationStride))
            }
        }
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) { CVBufferSetAttachments(destination, attachments, .shouldPropagate) }
        return sampleBuffer(imageBuffer: destination, timingFrom: sample)
    }

    static func sampleBuffer(imageBuffer: CVPixelBuffer, timingFrom source: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
                                                          formatDescriptionOut: &format) == noErr,
              let description = format else { return nil }
        var timing = CMSampleTimingInfo(duration: source.duration, presentationTimeStamp: source.presentationTimeStamp,
                                        decodeTimeStamp: source.decodeTimeStamp)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    private static func pixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }
        let key = "\(width)x\(height):\(format)"
        if pool == nil || key != poolKey {
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                            kCVPixelBufferPixelFormatTypeKey as String: format,
                                            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolKey = key
        }
        guard let pool = pool else { return nil }
        var result: CVPixelBuffer?
        // Prevent a stalled writer from turning this pool into an unlimited allocation queue.
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &result) == kCVReturnSuccess else { return nil }
        return result
    }
}

/// A bounded, metadata-first video sampling policy. Audio never passes through this filter.
/// The caller serializes access on its media queue and supplies the original capture PTS.
final class RecordingFramePolicy {
    private let options: RecordingOptions
    private var lastAccepted: CMTime?
    private var lastActivity: CMTime?
    private var lastFingerprint: SHA256.Digest?
    private var lastEncodedFingerprint: SHA256.Digest?
    private var lastSize: CGSize?
    private(set) var skippedFrames = 0

    init(options: RecordingOptions) { self.options = options }

    func reset() {
        lastAccepted = nil; lastActivity = nil; lastFingerprint = nil; lastEncodedFingerprint = nil; lastSize = nil; skippedFrames = 0
    }

    func noteActivity(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        guard time.isNumeric else { return }
        if lastActivity == nil || time > lastActivity! { lastActivity = time }
    }

    func desiredFrameRate(at time: CMTime) -> Double {
        guard options.adaptiveFrameRate else { return options.frameRate }
        guard let activity = lastActivity else { return options.adaptiveActiveFPS }
        return CMTimeGetSeconds(time - activity) >= options.adaptiveIdleSeconds
            ? options.adaptiveIdleFPS : options.adaptiveActiveFPS
    }

    func shouldEncode(_ sample: CMSampleBuffer) -> Bool {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric, let image = sample.imageBuffer else { skippedFrames += 1; return false }
        let needsContentCheck = options.dropDuplicateFrames || options.adaptiveFrameRate
        var changed = true
        var currentFingerprint: SHA256.Digest?
        if needsContentCheck {
            let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            let knownUnchanged = hasEmptyDirtyRects(sample) && lastSize == size && lastFingerprint != nil
            if knownUnchanged {
                changed = false
                currentFingerprint = lastFingerprint
            } else {
                let fingerprint = fingerprint(image, exact: options.dropDuplicateFrames)
                currentFingerprint = fingerprint
                changed = fingerprint == nil || lastFingerprint == nil || fingerprint != lastFingerprint || lastSize != size
                lastFingerprint = fingerprint
            }
            lastSize = size
            if changed { noteActivity(at: pts) }
        }
        if lastActivity == nil { lastActivity = pts }
        let fps = desiredFrameRate(at: pts)
        if let last = lastAccepted {
            let elapsed = CMTimeGetSeconds(pts - last)
            if elapsed < 0 || elapsed + 0.000_01 < 1 / fps { skippedFrames += 1; return false }
            if options.dropDuplicateFrames, let fingerprint = currentFingerprint,
               fingerprint == lastEncodedFingerprint { skippedFrames += 1; return false }
        }
        lastAccepted = pts
        lastEncodedFingerprint = currentFingerprint
        return true
    }

    private func hasEmptyDirtyRects(_ sample: CMSampleBuffer) -> Bool {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = list.first?[.dirtyRects] as? [Any] else { return false }
        return raw.isEmpty
    }

    /// Exact hashing is opt-in for dedupe; adaptive-only capture samples a small grid.
    /// No captured surface or full-size bitmap is kept between calls.
    private func fingerprint(_ buffer: CVPixelBuffer, exact: Bool) -> SHA256.Digest? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let highDepth = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let knownPlanar = highDepth || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard (planar && knownPlanar) || format == kCVPixelFormatType_32BGRA
                || format == kCVPixelFormatType_64RGBAHalf else { return nil }
        var hash = SHA256()
        let planeCount = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        for plane in 0..<planeCount {
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let pointer = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer)
            guard let raw = pointer, width > 0, height > 0 else { return nil }
            let bytesPerPixel = planar ? (highDepth ? 2 : 1) * (plane == 0 ? 1 : 2)
                : (format == kCVPixelFormatType_64RGBAHalf ? 8 : 4)
            guard width * bytesPerPixel <= stride else { return nil }
            if exact {
                for row in 0..<height {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: raw.advanced(by: row * stride), count: width * bytesPerPixel))
                }
            } else {
                var grid = [UInt8]()
                grid.reserveCapacity(min(height, 48) * min(width, 96) * bytesPerPixel)
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                for row in 0..<min(height, 48) {
                    let y = row * (height - 1) / max(1, min(height, 48) - 1)
                    for column in 0..<min(width, 96) {
                        let x = column * (width - 1) / max(1, min(width, 96) - 1)
                        let offset = y * stride + x * bytesPerPixel
                        grid.append(contentsOf: UnsafeBufferPointer(start: bytes.advanced(by: offset), count: bytesPerPixel))
                    }
                }
                grid.withUnsafeBytes { hash.update(bufferPointer: $0) }
            }
        }
        return hash.finalize()
    }
}
