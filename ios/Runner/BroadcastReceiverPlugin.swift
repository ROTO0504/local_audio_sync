import Flutter
import UIKit
import Darwin

/// Broadcast Upload Extension からの音声 PCM をメインアプリで受け取る Flutter プラグイン。
///
/// チャネル:
///   MethodChannel "com.example.local_audio_sync/broadcast"
///     - startBroadcastReceiver  → UDS 受信を開始
///     - stopBroadcastReceiver   → UDS 受信を停止
///     - isBroadcasting          → 直近 1.5 秒以内にデータが届いていれば true
///
///   EventChannel "com.example.local_audio_sync/screenAudio"
///     Extension から届いた PCM16 ステレオ 48kHz バイト列を Flutter へ流す。
///
/// 旧 ScreenAudioPlugin と同じチャネル名を踏襲することで、
/// Dart 側の `screen_audio_capture_service.dart` 互換を維持する。
@objc class BroadcastReceiverPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    // MARK: - 設定

    private let appGroupId = "group.com.example.local_audio_sync"
    private let socketName = "audio.sock"

    /// EventChannel の sink。UI スレッドで触る。
    private var eventSink: FlutterEventSink?

    /// 受信用ソケット FD。
    private var recvFd: Int32 = -1

    /// 受信ループのバックグラウンド queue。
    private let recvQueue = DispatchQueue(
        label: "com.example.local_audio_sync.broadcast.recv",
        qos: .userInitiated
    )
    private var recvRunning = false

    /// 直近データ受信時刻(モノトニック秒)。
    private var lastPacketTime: TimeInterval = 0

    // MARK: - 登録

    @objc static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.local_audio_sync/broadcast",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.example.local_audio_sync/screenAudio",
            binaryMessenger: registrar.messenger()
        )
        let instance = BroadcastReceiverPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
        // Flutter のアプリ終了通知でクリーンアップしたいので登録
        registrar.addApplicationDelegate(instance)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startBroadcastReceiver", "startScreenCapture":
            // 後者は旧 API 互換用エイリアス
            startReceiver(result: result)
        case "stopBroadcastReceiver", "stopScreenCapture":
            stopReceiver(result: result)
        case "isBroadcasting":
            let now = monotonicNow()
            let active = recvRunning && (now - lastPacketTime) < 1.5
            result(active)
        case "appGroupId":
            result(appGroupId)
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

    // MARK: - 受信制御

    private func startReceiver(result: @escaping FlutterResult) {
        if recvRunning {
            result(nil)
            return
        }
        guard let containerUrl = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            result(FlutterError(
                code: "APP_GROUP_MISSING",
                message: "App Group コンテナが取得できません: \(appGroupId)。Xcode の Capabilities で App Groups を有効化してください。",
                details: nil
            ))
            return
        }
        let socketPath = containerUrl.appendingPathComponent(socketName).path

        // 既存ソケットファイルを削除(前回の残骸対策)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 {
            result(FlutterError(
                code: "SOCKET_FAILED",
                message: "socket() 失敗: errno=\(errno)",
                details: nil
            ))
            return
        }

        // bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCStr = socketPath.cString(using: .utf8) ?? []
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        if pathCStr.count > maxLen {
            close(fd)
            result(FlutterError(
                code: "PATH_TOO_LONG",
                message: "ソケットパスが長すぎます: \(socketPath)",
                details: nil
            ))
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cPtr in
                for i in 0 ..< pathCStr.count {
                    cPtr[i] = pathCStr[i]
                }
            }
        }

        let bindStatus = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            return addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                return Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindStatus < 0 {
            close(fd)
            result(FlutterError(
                code: "BIND_FAILED",
                message: "bind() 失敗: errno=\(errno) path=\(socketPath)",
                details: nil
            ))
            return
        }

        // 受信バッファを少し大きめに(20ms フレーム × 数フレーム分)
        var rcvBuf: Int32 = 65536
        setsockopt(
            fd, SOL_SOCKET, SO_RCVBUF,
            &rcvBuf, socklen_t(MemoryLayout<Int32>.size)
        )

        recvFd = fd
        recvRunning = true
        lastPacketTime = monotonicNow()

        // バックグラウンドで recvfrom ループ
        recvQueue.async { [weak self] in
            self?.runReceiveLoop()
        }

        result(nil)
    }

    private func stopReceiver(result: @escaping FlutterResult) {
        recvRunning = false
        if recvFd >= 0 {
            // shutdown で recvfrom をブロックから抜けさせる
            shutdown(recvFd, SHUT_RDWR)
            close(recvFd)
            recvFd = -1
        }
        result(nil)
    }

    private func runReceiveLoop() {
        let bufferSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while recvRunning && recvFd >= 0 {
            let received = buffer.withUnsafeMutableBufferPointer { ptr -> ssize_t in
                return recvfrom(recvFd, ptr.baseAddress, bufferSize, 0, nil, nil)
            }
            if received <= 0 {
                if errno == EINTR { continue }
                // ソケットが閉じられた等
                break
            }

            let bytes = Array(buffer.prefix(Int(received)))
            lastPacketTime = monotonicNow()

            // EventChannel 送信は main queue で
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let sink = self.eventSink else { return }
                sink(FlutterStandardTypedData(bytes: Data(bytes)))
            }
        }
    }

    // MARK: - ライフサイクル

    func applicationWillTerminate(_ application: UIApplication) {
        recvRunning = false
        if recvFd >= 0 {
            close(recvFd)
            recvFd = -1
        }
    }

    private func monotonicNow() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}
