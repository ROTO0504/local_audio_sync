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
///   Packets are arbitrarily sized; the Dart side buffers them into
///   3 840-byte (20 ms @ 48 kHz stereo PCM16) chunks.
@objc class ScreenAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private let recorder = RPScreenRecorder.shared()

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

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
        recorder.stopCapture { [weak self] error in
            self?.converter = nil
            self?.outputFormat = nil
            if let error = error {
                result(FlutterError(code: "STOP_FAILED",
                                   message: error.localizedDescription,
                                   details: nil))
            } else {
                result(nil)
            }
        }
    }

    // MARK: – Audio processing

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let sink = eventSink else { return }

        // Build the converter lazily on the first buffer so we know the
        // source format from the actual hardware output.
        if converter == nil {
            guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let srcFmt = AVAudioFormat(cmAudioFormatDescription: desc),
                  let dstFmt = AVAudioFormat(
                      standardFormatWithSampleRate: 48_000, channels: 2),
                  let conv = AVAudioConverter(from: srcFmt, to: dstFmt) else { return }
            converter = conv
            outputFormat = dstFmt
        }

        guard let conv = converter, let outFmt = outputFormat else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        // Wrap CMSampleBuffer audio data in an AVAudioPCMBuffer
        guard let inputBuf = makePCMBuffer(from: sampleBuffer,
                                           format: conv.inputFormat) else { return }

        // Allocate output buffer with headroom for SRC ratio
        let ratio = outFmt.sampleRate / conv.inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 64)
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: outFmt,
                                               frameCapacity: outCapacity) else { return }

        // Provide input exactly once; return .noDataNow on subsequent calls
        var inputConsumed = false
        var convertError: NSError?
        conv.convert(to: outputBuf, error: &convertError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuf
        }

        guard convertError == nil, outputBuf.frameLength > 0 else { return }

        // Convert non-interleaved Float32 → interleaved Int16
        let pcm16 = toInterleavedInt16(outputBuf)
        guard !pcm16.isEmpty else { return }

        let typedData = FlutterStandardTypedData(bytes: pcm16)
        DispatchQueue.main.async {
            sink(typedData)
        }
    }

    /// Extract audio bytes from a CMSampleBuffer into a new AVAudioPCMBuffer
    /// using the safe CoreMedia API.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                               format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount

        // Copy PCM data from the CMSampleBuffer into the AudioBufferList of buf
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buf.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buf
    }

    /// Convert a non-interleaved Float32 AVAudioPCMBuffer to interleaved Int16 Data.
    private func toInterleavedInt16(_ buf: AVAudioPCMBuffer) -> Data {
        let frames = Int(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        var out = Data(count: frames * channels * 2)
        out.withUnsafeMutableBytes { rawPtr in
            let dst = rawPtr.bindMemory(to: Int16.self)
            for f in 0 ..< frames {
                for ch in 0 ..< channels {
                    let sample = buf.floatChannelData![ch][f]
                    let clamped = max(-1.0, min(1.0, sample))
                    dst[f * channels + ch] = Int16(clamped * 32_767)
                }
            }
        }
        return out
    }
}
