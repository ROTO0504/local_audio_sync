import AVFoundation
import Flutter
import ReplayKit
import UIKit

/// Captures system audio (all apps) via RPScreenRecorder and streams raw
/// PCM-16 bytes back to Flutter through an EventChannel.
///
/// MethodChannel  : "com.example.local_audio_sync/broadcast"
///   startScreenCapture  → starts RPScreenRecorder, returns nil on success
///   stopScreenCapture   → stops recording
///
/// EventChannel   : "com.example.local_audio_sync/screenAudio"
///   Delivers FlutterStandardTypedData(bytes:) packets of interleaved
///   PCM-16LE stereo at 48 000 Hz.  Each packet may be any size; the Dart
///   side buffers them into 3 840-byte (20 ms) chunks.
@objc class ScreenAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?
    private let recorder = RPScreenRecorder.shared()

    // AVAudioConverter for Float32 → Int16 and optional resampling
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // MARK: – FlutterPlugin registration

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

    // MARK: – FlutterPlugin method handler

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScreenCapture":
            startCapture(result: result)
        case "stopScreenCapture":
            stopCapture(result: result)
        default:
            // Let other handlers (e.g. Android broadcast service stubs) fall through
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
        converter = nil
        outputFormat = nil
    }

    // MARK: – PCM conversion

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let sink = eventSink else { return }

        // Lazily build the converter on the first buffer so we know the
        // source format (sample rate, channel count, etc.) from the hardware.
        if converter == nil {
            setupConverter(for: sampleBuffer)
        }

        guard let conv = converter,
              let outFmt = outputFormat else { return }

        // Wrap the CMSampleBuffer in an AVAudioPCMBuffer for the converter.
        guard let inputBlock = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let inputFmt = conv.inputFormat as AVAudioFormat?,
              let inputBuf = AVAudioPCMBuffer(
                pcmFormat: inputFmt,
                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inputBuf.frameLength = AVAudioFrameCount(frameCount)

        // Copy raw bytes from CMBlockBuffer into the AVAudioPCMBuffer.
        var dataPointer: UnsafeMutablePointer<Int8>?
        var totalLength = 0
        CMBlockBufferGetDataPointer(inputBlock,
                                   atOffset: 0,
                                   lengthAtOffsetOut: nil,
                                   totalLengthOut: &totalLength,
                                   dataPointerOut: &dataPointer)
        guard let src = dataPointer else { return }

        if let channelData = inputBuf.floatChannelData {
            let bytesPerChannel = totalLength / Int(inputFmt.channelCount)
            for ch in 0 ..< Int(inputFmt.channelCount) {
                memcpy(channelData[ch], src.advanced(by: ch * bytesPerChannel),
                       bytesPerChannel)
            }
        } else if let int16Data = inputBuf.int16ChannelData {
            let bytesPerChannel = totalLength / Int(inputFmt.channelCount)
            for ch in 0 ..< Int(inputFmt.channelCount) {
                memcpy(int16Data[ch], src.advanced(by: ch * bytesPerChannel),
                       bytesPerChannel)
            }
        }

        // Allocate output buffer (ratio of sample rates + some headroom).
        let ratio = outFmt.sampleRate / inputFmt.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio + 1)
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: outFmt,
                                               frameCapacity: outFrames) else { return }

        var error: NSError?
        conv.convert(to: outputBuf, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuf
        }

        guard error == nil, outputBuf.frameLength > 0 else { return }

        // outputBuf contains non-interleaved Float32.  Convert to interleaved Int16.
        let outFrameLen = Int(outputBuf.frameLength)
        let channels = Int(outFmt.channelCount)
        var int16Bytes = Data(count: outFrameLen * channels * 2)

        int16Bytes.withUnsafeMutableBytes { rawPtr in
            let ptr = rawPtr.bindMemory(to: Int16.self)
            for frame in 0 ..< outFrameLen {
                for ch in 0 ..< channels {
                    let sample = outputBuf.floatChannelData![ch][frame]
                    let clamped = max(-1.0, min(1.0, sample))
                    ptr[frame * channels + ch] = Int16(clamped * 32_767)
                }
            }
        }

        let typedData = FlutterStandardTypedData(bytes: int16Bytes)
        DispatchQueue.main.async {
            sink(typedData)
        }
    }

    /// Build an AVAudioConverter from the source format (as reported by the
    /// first RPScreenRecorder sample) to 48 000 Hz / stereo / Float32.
    private func setupConverter(for sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let srcFmt = AVAudioFormat(cmAudioFormatDescription: desc) else { return }

        // Target: 48 000 Hz, stereo, non-interleaved Float32
        guard let dstFmt = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2) else { return }

        outputFormat = dstFmt

        guard let conv = AVAudioConverter(from: srcFmt, to: dstFmt) else { return }
        converter = conv
    }
}
