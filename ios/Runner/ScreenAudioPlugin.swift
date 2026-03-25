import AVFoundation
import CoreMedia
import Flutter
import ReplayKit
import UIKit

/// Captures system audio (all apps on the device) via RPScreenRecorder and
/// streams interleaved PCM-16LE stereo @ 48 000 Hz back to Flutter through
/// an EventChannel.
///
/// MethodChannel  "com.example.local_audio_sync/broadcast"
///   startScreenCapture  → starts recording; returns nil on success
///   stopScreenCapture   → stops recording
///
/// EventChannel   "com.example.local_audio_sync/screenAudio"
///   Delivers FlutterStandardTypedData(bytes:) packets.
///   The Dart side buffers them into 3 840-byte (20 ms @ 48 kHz stereo PCM16) chunks.
@objc class ScreenAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private let recorder = RPScreenRecorder.shared()

    // MARK: – Registration

    @objc static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.local_audio_sync/broadcast",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.example.local_audio_sync/screenAudio",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScreenAudioPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: – FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScreenCapture":
            startCapture(result: result)
        case "stopScreenCapture":
            stopCapture(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: – FlutterStreamHandler

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: – Capture control

    private func startCapture(result: @escaping FlutterResult) {
        guard recorder.isAvailable else {
            result(FlutterError(code: "UNAVAILABLE",
                               message: "RPScreenRecorder is not available on this device",
                               details: nil))
            return
        }

        recorder.startCapture(
            handler: { [weak self] sampleBuffer, bufferType, error in
                guard error == nil, bufferType == .audioApp else { return }
                self?.processSampleBuffer(sampleBuffer)
            },
            completionHandler: { error in
                if let error = error {
                    result(FlutterError(code: "START_FAILED",
                                       message: error.localizedDescription,
                                       details: nil))
                } else {
                    result(nil)
                }
            }
        )
    }

    private func stopCapture(result: @escaping FlutterResult) {
        recorder.stopCapture { error in
            if let error = error {
                result(FlutterError(code: "STOP_FAILED",
                                   message: error.localizedDescription,
                                   details: nil))
            } else {
                result(nil)
            }
        }
    }

    // MARK: – PCM conversion

    /// Convert a CMSampleBuffer from RPScreenRecorder (.audioApp) to
    /// interleaved PCM-16LE and send it through the EventChannel.
    ///
    /// RPScreenRecorder delivers non-interleaved Float32 PCM at the device's
    /// native sample rate (typically 48 000 Hz on modern iOS devices).
    /// We convert Float32 → Int16 in-place; no sample-rate conversion is
    /// needed as long as the device's audio session runs at 48 kHz.
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let sink = eventSink else { return }

        // --- Get the raw block buffer ---
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        guard byteLength > 0 else { return }

        // Copy all bytes out of the (possibly non-contiguous) block buffer
        var rawBytes = [UInt8](repeating: 0, count: byteLength)
        let copyStatus = rawBytes.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(blockBuffer,
                                      atOffset: 0,
                                      dataLength: byteLength,
                                      destination: ptr.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        // --- Determine audio layout from the format description ---
        // RPScreenRecorder typically delivers non-interleaved Float32.
        // We need channel count to interleave correctly.
        var channelCount = 2  // safe default for stereo
        var isFloat = true    // RPScreenRecorder always delivers Float32
        var isInterleaved = false

        if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
                isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                isInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            }
        }

        let pcm16 = convertToInterleavedInt16(
            bytes: rawBytes,
            channelCount: channelCount,
            isFloat: isFloat,
            isInterleaved: isInterleaved
        )
        guard !pcm16.isEmpty else { return }

        let typedData = FlutterStandardTypedData(bytes: pcm16)
        DispatchQueue.main.async {
            sink(typedData)
        }
    }

    /// Convert raw audio bytes to interleaved Int16 PCM.
    /// Handles both Float32 and Int16 source formats, and both
    /// interleaved and non-interleaved layouts.
    private func convertToInterleavedInt16(bytes: [UInt8],
                                            channelCount: Int,
                                            isFloat: Bool,
                                            isInterleaved: Bool) -> Data {
        let ch = max(1, channelCount)

        if isFloat {
            // Float32: 4 bytes per sample
            let totalSamples = bytes.count / 4
            let framesPerChannel = totalSamples / ch
            var out = Data(count: framesPerChannel * ch * 2)

            bytes.withUnsafeBytes { rawPtr in
                let floats = rawPtr.bindMemory(to: Float32.self)
                out.withUnsafeMutableBytes { outRaw in
                    let int16s = outRaw.bindMemory(to: Int16.self)
                    for frame in 0 ..< framesPerChannel {
                        for c in 0 ..< ch {
                            // Non-interleaved: samples for channel c start at c * framesPerChannel
                            let srcIdx = isInterleaved ? (frame * ch + c) : (c * framesPerChannel + frame)
                            let dstIdx = frame * ch + c
                            guard srcIdx < totalSamples else { continue }
                            let f = floats[srcIdx]
                            let clamped = f < -1.0 ? -1.0 : (f > 1.0 ? 1.0 : f)
                            int16s[dstIdx] = Int16(clamped * 32_767)
                        }
                    }
                }
            }
            return out
        } else {
            // Already Int16: 2 bytes per sample, assume interleaved
            return Data(bytes)
        }
    }
}
