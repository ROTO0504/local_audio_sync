import AVFoundation
import CoreMedia
import FlutterMacOS
import ScreenCaptureKit

/// macOS 用の内部音声(他アプリの再生音)キャプチャプラグイン。
///
/// macOS 13 以降で利用可能な ScreenCaptureKit の `SCStream` を使用し、
/// `SCStreamConfiguration.capturesAudio = true` でシステム音声を取得する。
///
/// チャネル名は iOS と統一(Dart 側 ScreenAudioCaptureService 互換):
///   MethodChannel  "com.example.local_audio_sync/broadcast"
///     - startScreenCapture
///     - stopScreenCapture
///   EventChannel   "com.example.local_audio_sync/screenAudio"
///     PCM16 ステレオ 48 kHz の生バイト列を送る。
///
/// 取得直後の音声は通常 Float32 / 非インターリーブで来るため、
/// PCM16 / インターリーブに変換してから送出する。
@available(macOS 13.0, *)
@objc class ScreenCaptureKitPlugin: NSObject,
    FlutterPlugin,
    FlutterStreamHandler,
    SCStreamDelegate,
    SCStreamOutput {

    private var eventSink: FlutterEventSink?
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(
        label: "com.example.local_audio_sync.screencapturekit",
        qos: .userInitiated
    )

    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.local_audio_sync/broadcast",
            binaryMessenger: registrar.messenger
        )
        let eventChannel = FlutterEventChannel(
            name: "com.example.local_audio_sync/screenAudio",
            binaryMessenger: registrar.messenger
        )
        let instance = ScreenCaptureKitPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScreenCapture":
            Task {
                do {
                    try await self.startCapture()
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "START_FAILED",
                            message: "ScreenCaptureKit 開始失敗: \(error.localizedDescription)",
                            details: nil
                        ))
                    }
                }
            }
        case "stopScreenCapture":
            Task {
                await self.stopCapture()
                DispatchQueue.main.async { result(nil) }
            }
        case "isBroadcasting":
            // macOS では「配信中」概念はないので、ストリームが生きていれば true
            result(stream != nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - キャプチャ制御

    private func startCapture() async throws {
        if stream != nil { return }

        // 利用可能な共有コンテンツ(画面・ウィンドウ・アプリ)を取得
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(
                domain: "ScreenCaptureKitPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "利用可能なディスプレイが見つかりません"]
            )
        }

        // すべてのウィンドウを含めるが映像はミニマル設定(音声だけ欲しいので)
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 映像も最小サイズで取らざるを得ないので 2x2 で軽量化
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let newStream = SCStream(
            filter: filter,
            configuration: config,
            delegate: self
        )
        try newStream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: outputQueue
        )
        try await newStream.startCapture()
        stream = newStream
    }

    private func stopCapture() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
        } catch {
            NSLog("[ScreenCaptureKitPlugin] stopCapture 例外: \(error)")
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.dataReadiness == .ready else { return }
        guard let pcm16 = convertSampleBufferToPcm16Stereo(sampleBuffer) else {
            return
        }
        let data = FlutterStandardTypedData(bytes: pcm16)
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(data)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[ScreenCaptureKitPlugin] ストリーム停止: \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(FlutterError(
                code: "STREAM_STOPPED",
                message: error.localizedDescription,
                details: nil
            ))
        }
        self.stream = nil
    }

    // MARK: - PCM 変換

    /// CMSampleBuffer(通常 Float32 non-interleaved 48 kHz)→ PCM16 stereo interleaved
    private func convertSampleBufferToPcm16Stereo(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        let totalBytes = CMBlockBufferGetDataLength(blockBuffer)
        guard totalBytes > 0 else { return nil }

        var rawBytes = [UInt8](repeating: 0, count: totalBytes)
        let copyStatus = rawBytes.withUnsafeMutableBytes { ptr -> OSStatus in
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalBytes,
                destination: ptr.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var channelCount = 2
        var isFloat = true
        var isInterleaved = false
        var sampleRate: Float64 = 48_000

        if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) {
            channelCount = Int(asbd.pointee.mChannelsPerFrame)
            isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            isInterleaved =
                (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            sampleRate = asbd.pointee.mSampleRate
        }

        // 48kHz 以外は本実装では非対応(設計上 48kHz 前提)
        if abs(sampleRate - 48_000) > 1.0 {
            NSLog("[ScreenCaptureKitPlugin] 非対応サンプルレート \(sampleRate) Hz")
            return nil
        }

        let ch = max(1, channelCount)

        if isFloat {
            let totalSamples = totalBytes / 4
            let framesPerChannel = totalSamples / ch
            if framesPerChannel == 0 { return nil }

            // 出力は常にステレオ(片チャンネルしか無ければ複製)
            let outChannels = 2
            var out = Data(count: framesPerChannel * outChannels * 2)

            rawBytes.withUnsafeBytes { rawPtr in
                let floats = rawPtr.bindMemory(to: Float32.self)
                out.withUnsafeMutableBytes { outRaw in
                    let int16s = outRaw.bindMemory(to: Int16.self)
                    for frame in 0 ..< framesPerChannel {
                        for outC in 0 ..< outChannels {
                            let srcChannel = min(outC, ch - 1)
                            let srcIdx = isInterleaved
                                ? (frame * ch + srcChannel)
                                : (srcChannel * framesPerChannel + frame)
                            guard srcIdx < totalSamples else { continue }
                            var f = floats[srcIdx]
                            if f > 1.0 { f = 1.0 } else if f < -1.0 { f = -1.0 }
                            int16s[frame * outChannels + outC] = Int16(f * 32_767)
                        }
                    }
                }
            }
            return out
        } else {
            // Int16 の場合(ScreenCaptureKit ではほぼ来ないが念のため)
            return Data(rawBytes)
        }
    }
}

/// macOS 12 以下でも参照しやすいよう薄いラッパを提供。
/// 古い OS では何もしない(エラー応答する)。
@objc class ScreenCaptureKitPluginLoader: NSObject {
    @objc static func register(with registrar: FlutterPluginRegistrar) {
        if #available(macOS 13.0, *) {
            ScreenCaptureKitPlugin.register(with: registrar)
        } else {
            // macOS 12 以下: スタブとしてだけ登録し、呼び出されたらエラーを返す
            UnsupportedScreenCapturePlugin.register(with: registrar)
        }
    }
}

/// macOS 13 未満用のフォールバック。
@objc class UnsupportedScreenCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.local_audio_sync/broadcast",
            binaryMessenger: registrar.messenger
        )
        let eventChannel = FlutterEventChannel(
            name: "com.example.local_audio_sync/screenAudio",
            binaryMessenger: registrar.messenger
        )
        let instance = UnsupportedScreenCapturePlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(FlutterError(
            code: "UNSUPPORTED_OS",
            message: "macOS 13 以降が必要です",
            details: nil
        ))
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        return FlutterError(code: "UNSUPPORTED_OS",
                            message: "macOS 13 以降が必要です",
                            details: nil)
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        return nil
    }
}
