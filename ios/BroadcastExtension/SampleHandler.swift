import ReplayKit
import AVFoundation
import Darwin

/// Broadcast Upload Extension の本体。
///
/// ReplayKit から渡される CMSampleBuffer のうち `audioApp`(他アプリも含む
/// デバイス全体の出力音声)を取り出し、Float32 → PCM16 ステレオに変換して
/// App Group コンテナ内の UNIX Domain Socket(SOCK_DGRAM)経由で
/// メインアプリへ転送する。
///
/// 50MB のメモリ制限があるため、Extension 内では Opus エンコードや
/// UDP 送信などの重い処理は行わず、PCM 変換と転送のみに専念する。
///
/// IPC 経路:
///   App Group コンテナ + 固定ファイル名("audio.sock") のソケットファイル。
///   メインアプリ側が listening し、こちらは sendto で書き込む側。
@objc(SampleHandler)
class SampleHandler: RPBroadcastSampleHandler {

    /// App Group 識別子(メインアプリと同じ値にする)。
    private let appGroupId = "group.com.roto0504.localAudioSync"

    /// ソケットファイル名(コンテナ直下に配置)。
    private let socketName = "audio.sock"

    /// 送信用ソケット FD。生成失敗時は -1。
    private var sendFd: Int32 = -1

    /// 接続先のソケットアドレス。
    private var serverAddr = sockaddr_un()

    /// 50MB 制限を超えないように、変換用の中間バッファを使い回す。
    private var pcm16Buffer = [Int16](repeating: 0, count: 16384)

    /// 一度の送信で扱う最大バイト数(IPC 上限の安全側)。
    /// SOCK_DGRAM の SO_SNDBUF 既定よりやや小さく取る。
    private let maxChunkBytes = 8192

    /// 直近のエラー回数(過剰ログ抑止用)。
    private var errorCount = 0
    private let maxLoggedErrors = 5

    // MARK: - ライフサイクル

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        prepareSocket()
        NSLog("[BroadcastExtension] broadcastStarted, sendFd=\(sendFd)")
    }

    override func broadcastPaused() {
        // ユーザーが配信を一時停止。FD は維持。
    }

    override func broadcastResumed() {
        // ユーザーが再開。FD が無効化されていれば作り直す。
        if sendFd < 0 {
            prepareSocket()
        }
    }

    override func broadcastFinished() {
        if sendFd >= 0 {
            close(sendFd)
            sendFd = -1
        }
        NSLog("[BroadcastExtension] broadcastFinished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        // .audioApp = 他アプリ含むデバイス全体の出力音声(欲しいやつ)
        // .audioMic = マイク(今回は不要)
        // .video    = 画面映像(不要)
        guard sampleBufferType == .audioApp else { return }
        guard sendFd >= 0 else { return }

        sendAudioBuffer(sampleBuffer)
    }

    // MARK: - ソケット準備

    private func prepareSocket() {
        guard let containerUrl = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            NSLog("[BroadcastExtension] App Group コンテナが取得できません: \(appGroupId)")
            return
        }
        let socketPath = containerUrl.appendingPathComponent(socketName).path

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 {
            NSLog("[BroadcastExtension] socket() 失敗: errno=\(errno)")
            return
        }

        // ノンブロッキング。受信側が居ないときに send が詰まらないように。
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // 送信先アドレス設定
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // sun_path に socketPath をコピー(108 バイト固定)
        let pathCStr = socketPath.cString(using: .utf8) ?? []
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        if pathCStr.count > maxLen {
            NSLog("[BroadcastExtension] ソケットパスが長すぎます: \(socketPath)")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cPtr in
                for i in 0 ..< pathCStr.count {
                    cPtr[i] = pathCStr[i]
                }
            }
        }

        sendFd = fd
        serverAddr = addr
    }

    // MARK: - 音声バッファ送信

    private func sendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        guard byteLength > 0 else { return }

        // フォーマット情報を取り出す(ASBD 経由)
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

        // 48kHz 以外が来た場合は今は素直に変換せずスキップ(設計上 48kHz 前提)
        if abs(sampleRate - 48_000) > 1.0 {
            logErrorOnce("予期しないサンプルレート \(sampleRate) Hz をスキップ")
            return
        }

        // 生バイトを連続領域へコピー
        var rawBytes = [UInt8](repeating: 0, count: byteLength)
        let copyStatus = rawBytes.withUnsafeMutableBytes { ptr -> OSStatus in
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteLength,
                destination: ptr.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            logErrorOnce("CMBlockBufferCopyDataBytes 失敗: \(copyStatus)")
            return
        }

        // PCM16 インターリーブへ変換
        let pcm16Bytes = convertToInterleavedInt16(
            bytes: rawBytes,
            channelCount: max(1, channelCount),
            isFloat: isFloat,
            isInterleaved: isInterleaved
        )
        guard !pcm16Bytes.isEmpty else { return }

        // 大きすぎるバッファはチャンク分割して送る
        var offset = 0
        while offset < pcm16Bytes.count {
            let remaining = pcm16Bytes.count - offset
            let chunkLen = min(remaining, maxChunkBytes)
            let endIndex = offset + chunkLen
            // 偶数バイト境界(PCM16 = 1 サンプル 2 byte、ステレオなら 4 byte)を維持
            // ステレオサンプル境界は 4 byte なので 4 の倍数に揃える
            let aligned = chunkLen - (chunkLen % 4)
            if aligned <= 0 { break }
            let chunk = pcm16Bytes[offset ..< (offset + aligned)]
            sendChunk(Array(chunk))
            offset += aligned
            _ = endIndex
        }
    }

    private func sendChunk(_ data: [UInt8]) {
        guard sendFd >= 0 else { return }
        let sent = data.withUnsafeBufferPointer { buf -> ssize_t in
            return withUnsafePointer(to: &serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    return sendto(
                        sendFd,
                        buf.baseAddress,
                        data.count,
                        0,
                        saPtr,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        if sent < 0 {
            // EAGAIN/EWOULDBLOCK は受信側が遅いだけなので無視。
            // ENOENT/ECONNREFUSED はソケットが消えた可能性 → 次回 resume で再生成。
            if errno == ENOENT || errno == ECONNREFUSED {
                close(sendFd)
                sendFd = -1
            }
            logErrorOnce("sendto 失敗: errno=\(errno)")
        }
    }

    // MARK: - PCM 変換

    /// Float32(non-interleaved もしくは interleaved)→ Int16 interleaved。
    /// バイト列で返す(ステレオなら [L0lo, L0hi, R0lo, R0hi, L1lo, ...])。
    private func convertToInterleavedInt16(bytes: [UInt8],
                                            channelCount: Int,
                                            isFloat: Bool,
                                            isInterleaved: Bool) -> [UInt8] {
        let ch = max(1, channelCount)

        if isFloat {
            let totalSamples = bytes.count / 4
            let framesPerChannel = totalSamples / ch
            if framesPerChannel == 0 { return [] }
            var out = [UInt8](repeating: 0, count: framesPerChannel * ch * 2)

            bytes.withUnsafeBytes { rawPtr in
                let floats = rawPtr.bindMemory(to: Float32.self)
                out.withUnsafeMutableBytes { outRaw in
                    let int16s = outRaw.bindMemory(to: Int16.self)
                    for frame in 0 ..< framesPerChannel {
                        for c in 0 ..< ch {
                            let srcIdx = isInterleaved
                                ? (frame * ch + c)
                                : (c * framesPerChannel + frame)
                            let dstIdx = frame * ch + c
                            guard srcIdx < totalSamples else { continue }
                            var f = floats[srcIdx]
                            if f > 1.0 { f = 1.0 } else if f < -1.0 { f = -1.0 }
                            int16s[dstIdx] = Int16(f * 32_767)
                        }
                    }
                }
            }
            return out
        } else {
            // 既に Int16(と仮定)、interleaved ならそのまま返却
            if isInterleaved {
                return bytes
            }
            // non-interleaved Int16 → interleaved に並べ替え
            let totalSamples = bytes.count / 2
            let framesPerChannel = totalSamples / ch
            if framesPerChannel == 0 { return [] }
            var out = [UInt8](repeating: 0, count: framesPerChannel * ch * 2)
            bytes.withUnsafeBytes { rawPtr in
                let src = rawPtr.bindMemory(to: Int16.self)
                out.withUnsafeMutableBytes { outRaw in
                    let dst = outRaw.bindMemory(to: Int16.self)
                    for frame in 0 ..< framesPerChannel {
                        for c in 0 ..< ch {
                            let srcIdx = c * framesPerChannel + frame
                            let dstIdx = frame * ch + c
                            dst[dstIdx] = src[srcIdx]
                        }
                    }
                }
            }
            return out
        }
    }

    // MARK: - ログ抑止

    private func logErrorOnce(_ message: String) {
        if errorCount < maxLoggedErrors {
            NSLog("[BroadcastExtension] %@", message)
            errorCount += 1
        }
    }
}
