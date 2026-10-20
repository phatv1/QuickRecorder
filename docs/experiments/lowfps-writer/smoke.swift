// Offline synthetic smoke test; does not use ScreenCaptureKit or record the screen.
// Run on macOS: swift docs/experiments/lowfps-writer/smoke.swift
// Generates/replaces only its four named MP4 files under /tmp/qr-lowfps-smoke.
// Tests hardware-required H.264/HEVC with sparse video, continuous synthetic AAC,
// explicit video sample durations and a 16-second session. No fragmentation.
// This is a research harness, not production recorder code or a CPU/RAM benchmark.

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics
import AppKit
import AudioToolbox
import VideoToolbox

let root = URL(fileURLWithPath: "/tmp/qr-lowfps-smoke", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let duration = 16.0
let width = 1280
let height = 720
let audioRate = 24000

func frame(_ index: Int, _ time: Double) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let pixel = result else { throw NSError(domain: "pixels", code: Int(status)) }
    CVPixelBufferLockBaseAddress(pixel, [])
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let text = "Synthetic screen, frame \(index), PTS \(time) s\nEmployee portal / Invoice 4821 / Total $1250\nExample 12px: abcdefghijklmnopqrstuvwxyz 0123456789"
    (text as NSString).draw(at: NSPoint(x: 80, y: 200), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    return pixel
}

func videoSample(_ index: Int, _ time: Double, _ interval: Double) throws -> CMSampleBuffer {
    let pixel = try frame(index, time)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(seconds: min(interval, duration - time), preferredTimescale: 60000), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &result)
    return result!
}

var asbd = AudioStreamBasicDescription(mSampleRate: Double(audioRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
var audioFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)

func audioSample(_ offset: Int, _ count: Int) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
    let data = (0..<count).map { Int16(sin(Double(offset + $0) * 2 * Double.pi * 440 / Double(audioRate)) * 8000) }
    data.withUnsafeBytes { bytes in _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 2) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(audioRate)), presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(audioRate)), decodeTimeStamp: .invalid)
    var size = 2
    var result: CMSampleBuffer?
    CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result)
    return result!
}

for codec in [AVVideoCodecType.h264, .hevc] {
    for fps in [0.2, 0.5] {
        let url = root.appendingPathComponent("\(codec.rawValue)-\(fps).mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 150000, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 10.0]
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        video.expectsMediaDataInRealTime = false
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { fatalError("start \(writer.error!)") }
        writer.startSession(atSourceTime: .zero)
        var videoIndex = 0
        var audioOffset = 0
        let interval = 1.0 / fps
        let totalAudio = Int(duration) * audioRate
        let began = Date()
        var videoFinished = false
        var audioFinished = false
        while !videoFinished || !audioFinished {
            if writer.status == .failed { fatalError("write \(writer.error!)") }
            if Date().timeIntervalSince(began) > 30 { fatalError("timeout") }
            if !videoFinished && Double(videoIndex) * interval >= duration { video.markAsFinished(); videoFinished = true }
            if !audioFinished && audioOffset >= totalAudio { audio.markAsFinished(); audioFinished = true }
            if !videoFinished && video.isReadyForMoreMediaData {
                let sample = try videoSample(videoIndex, Double(videoIndex) * interval, interval)
                guard video.append(sample) else { fatalError("video \(String(describing: writer.error))") }
                videoIndex += 1
            }
            if !audioFinished && audio.isReadyForMoreMediaData {
                let count = min(1024, totalAudio - audioOffset)
                guard audio.append(try audioSample(audioOffset, count)) else { fatalError("audio \(String(describing: writer.error))") }
                audioOffset += count
            }
            usleep(100)
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        print("\(url.path): \(writer.status.rawValue) \(String(describing: writer.error)); videoFrames=\(videoIndex) audioSamples=\(audioOffset); hardwareRequired=true")
    }
}
