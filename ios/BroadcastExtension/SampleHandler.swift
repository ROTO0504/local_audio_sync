import ReplayKit
import AVFoundation
import Darwin

/// Broadcast Upload Extension の本体。
///
/// ReplayKit から渡される CMSampleBuffer のうち `audioApp`(他アプリも含む
/// デバイス全体の出力音声)を取り出し、**必ず 48kHz / PCM16 / ステレオ /
/// インターリーブ**へ正規化して、App Group コンテナ内の UNIX Domain Socket
/// (SOCK_DGRAM)経由でメインアプリへ転送する。
///
/// 以前はサンプルレートが 48000 以外だと全バッファを無言でスキップしていたが、
/// iOS の `.audioApp` は端末・再生元によって 44100Hz で来ることがあり、その場合
/// 1 フレームも届かず「音が何も来ない」状態になっていた。ここでは任意レートを
/// 線形補間で 48kHz へリサンプルし、モノは複製してステレオ化して必ず送る。
///
/// 50MB のメモリ制限があるため、Opus エンコードや UDP 送信などの重い処理は
/// 行わず、フォーマット正規化と UDS 転送のみに専念する。
///
/// 診断: App Group コンテナに `broadcast_status.txt` を定期的に書き出す。
/// メインアプリがこれを読み UI に表示することで、Xcode コンソール無しでも
/// 「コンテナ取得可否 / .audioApp 到達数 / 実フォーマット / 送信バイト / errno」
/// を確認でき、無音時の原因切り分けができる。
@objc(SampleHandler)
class SampleHandler: RPBroadcastSampleHandler {

    /// App Group 識別子(メインアプリと同じ値にする)。
    private let appGroupId = "group.com.roto0504.localAudioSync"

    /// ソケットファイル名(コンテナ直下に配置)。
    private let socketName = "audio.sock"

    /// 診断ファイル名。
    private let statusName = "broadcast_status.txt"

    /// 出力フォーマット(メインアプリ / Opus パイプラインの前提)。
    private let outSampleRate: Double = 48_000
    private let outChannels = 2

    /// 送信用ソケット FD。生成失敗時は -1。
    private var sendFd: Int32 = -1

    /// 接続先のソケットアドレス。
    private var serverAddr = sockaddr_un()

    /// コンテナ URL(診断ファイル書き込みにも使う)。
    private var containerUrl: URL?

    /// 一度の送信で扱う最大バイト数(IPC 上限の安全側)。
    private let maxChunkBytes = 8192

    // MARK: - 診断カウンタ

    private var containerOk = false
    private var appBuffers = 0
    private var micBuffers = 0
    private var videoBuffers = 0
    private var outChunks = 0
    private var outBytes = 0
    private var lastInRate: Double = 0
    private var lastInCh = 0
    private var lastInFloat = false
    private var lastErrno: Int32 = 0
    private var startedFlag = false
    /// 直近の診断書き込みからの経過を測るためのバッファカウンタ。
    private var buffersSinceStatus = 0

    private var errorCount = 0
    private let maxLoggedErrors = 5

    // MARK: - ライフサイクル

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedFlag = true
        prepareSocket()
        writeStatus()
        NSLog("[BroadcastExtension] broadcastStarted, sendFd=\(sendFd) container=\(containerOk)")
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {
        if sendFd < 0 { prepareSocket() }
    }

    override func broadcastFinished() {
        writeStatus()
        if sendFd >= 0 {
            close(sendFd)
            sendFd = -1
        }
        NSLog("[BroadcastExtension] broadcastFinished appBuffers=\(appBuffers) outBytes=\(outBytes)")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            appBuffers += 1
        case .audioMic:
            micBuffers += 1
            return
        case .video:
            videoBuffers += 1
            return
        @unknown default:
            return
        }

        if sendFd >= 0 {
            sendAudioBuffer(sampleBuffer)
        }

        // 25 バッファごと(概ね 0.5 秒ごと)に診断を書き出す。
        buffersSinceStatus += 1
        if buffersSinceStatus >= 25 {
            buffersSinceStatus = 0
            writeStatus()
        }
    }

    // MARK: - ソケット準備

    private func prepareSocket() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            containerOk = false
            NSLog("[BroadcastExtension] App Group コンテナが取得できません: \(appGroupId)")
            return
        }
        containerOk = true
        containerUrl = container
        let socketPath = container.appendingPathComponent(socketName).path

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        if fd < 0 {
            lastErrno = errno
            NSLog("[BroadcastExtension] socket() 失敗: errno=\(errno)")
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
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

        var channelCount = 2
        var isFloat = true
        var isInterleaved = false
        var sampleRate: Float64 = 48_000
        var bitsPerChannel = 32

        if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) {
            channelCount = Int(asbd.pointee.mChannelsPerFrame)
            isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            isInterleaved =
                (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            sampleRate = asbd.pointee.mSampleRate
            bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        }

        lastInRate = sampleRate
        lastInCh = channelCount
        lastInFloat = isFloat

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

        // 1) 入力を「ステレオ Float フレーム列」へデコード(任意レートのまま)
        let stereo = decodeToStereoFloat(
            bytes: rawBytes,
            channelCount: max(1, channelCount),
            isFloat: isFloat,
            isInterleaved: isInterleaved,
            bitsPerChannel: bitsPerChannel
        )
        guard !stereo.isEmpty else { return }

        // 2) 48kHz へ線形リサンプル(既に 48k ならそのまま)
        let resampled = resampleStereo(
            frames: stereo, fromRate: sampleRate, toRate: outSampleRate
        )
        guard !resampled.isEmpty else { return }

        // 3) Int16 インターリーブのバイト列へ
        let pcm16Bytes = floatStereoToInt16Bytes(resampled)
        guard !pcm16Bytes.isEmpty else { return }

        // 4) チャンク分割(ステレオ 1 サンプル = 4 byte 境界を維持)して送信
        var offset = 0
        while offset < pcm16Bytes.count {
            let remaining = pcm16Bytes.count - offset
            let chunkLen = min(remaining, maxChunkBytes)
            let aligned = chunkLen - (chunkLen % 4)
            if aligned <= 0 { break }
            let chunk = Array(pcm16Bytes[offset ..< (offset + aligned)])
            sendChunk(chunk)
            offset += aligned
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
            lastErrno = errno
            if errno == ENOENT || errno == ECONNREFUSED {
                close(sendFd)
                sendFd = -1
            }
            logErrorOnce("sendto 失敗: errno=\(errno)")
        } else {
            outChunks += 1
            outBytes += Int(sent)
        }
    }

    // MARK: - フォーマット正規化

    /// 入力バイト列を「ステレオ Float フレーム列」[L0, R0, L1, R1, ...] へデコードする。
    /// float / Int16、interleaved / planar、モノ/多チャンネルを吸収する。
    private func decodeToStereoFloat(bytes: [UInt8],
                                     channelCount: Int,
                                     isFloat: Bool,
                                     isInterleaved: Bool,
                                     bitsPerChannel: Int) -> [Float] {
        let ch = max(1, channelCount)
        var out: [Float] = []

        if isFloat {
            let totalSamples = bytes.count / 4
            let framesPerChannel = totalSamples / ch
            if framesPerChannel == 0 { return [] }
            out.reserveCapacity(framesPerChannel * 2)
            bytes.withUnsafeBytes { rawPtr in
                let floats = rawPtr.bindMemory(to: Float32.self)
                for frame in 0 ..< framesPerChannel {
                    let l = sampleFloat(floats, frame: frame, ch: 0, chCount: ch,
                                        framesPerChannel: framesPerChannel,
                                        isInterleaved: isInterleaved, total: totalSamples)
                    let r = ch >= 2
                        ? sampleFloat(floats, frame: frame, ch: 1, chCount: ch,
                                      framesPerChannel: framesPerChannel,
                                      isInterleaved: isInterleaved, total: totalSamples)
                        : l
                    out.append(l)
                    out.append(r)
                }
            }
        } else {
            // Int16(16bit 前提。それ以外の整数深度は稀なので 16bit として扱う)
            let bytesPerSample = max(2, bitsPerChannel / 8)
            if bytesPerSample != 2 { return [] } // 想定外の深度は送らない(診断で判別)
            let totalSamples = bytes.count / 2
            let framesPerChannel = totalSamples / ch
            if framesPerChannel == 0 { return [] }
            out.reserveCapacity(framesPerChannel * 2)
            bytes.withUnsafeBytes { rawPtr in
                let ints = rawPtr.bindMemory(to: Int16.self)
                for frame in 0 ..< framesPerChannel {
                    let l = sampleInt16(ints, frame: frame, ch: 0, chCount: ch,
                                        framesPerChannel: framesPerChannel,
                                        isInterleaved: isInterleaved, total: totalSamples)
                    let r = ch >= 2
                        ? sampleInt16(ints, frame: frame, ch: 1, chCount: ch,
                                      framesPerChannel: framesPerChannel,
                                      isInterleaved: isInterleaved, total: totalSamples)
                        : l
                    out.append(l)
                    out.append(r)
                }
            }
        }
        return out
    }

    private func sampleFloat(_ p: UnsafeBufferPointer<Float32>, frame: Int, ch: Int,
                             chCount: Int, framesPerChannel: Int,
                             isInterleaved: Bool, total: Int) -> Float {
        let idx = isInterleaved ? (frame * chCount + ch) : (ch * framesPerChannel + frame)
        guard idx < total else { return 0 }
        var f = p[idx]
        if f > 1.0 { f = 1.0 } else if f < -1.0 { f = -1.0 }
        return f
    }

    private func sampleInt16(_ p: UnsafeBufferPointer<Int16>, frame: Int, ch: Int,
                             chCount: Int, framesPerChannel: Int,
                             isInterleaved: Bool, total: Int) -> Float {
        let idx = isInterleaved ? (frame * chCount + ch) : (ch * framesPerChannel + frame)
        guard idx < total else { return 0 }
        return Float(p[idx]) / 32_768.0
    }

    /// ステレオ Float フレーム列を線形補間で fromRate → toRate へ変換する。
    private func resampleStereo(frames: [Float], fromRate: Double, toRate: Double) -> [Float] {
        if abs(fromRate - toRate) < 1.0 || fromRate <= 0 { return frames }
        let inFrames = frames.count / 2
        if inFrames < 2 { return frames }
        let ratio = toRate / fromRate
        let outFrames = Int(Double(inFrames) * ratio)
        if outFrames <= 0 { return [] }
        var out = [Float](repeating: 0, count: outFrames * 2)
        let step = fromRate / toRate // 入力フレーム / 出力フレーム
        var pos = 0.0
        for i in 0 ..< outFrames {
            let base = Int(pos)
            let frac = Float(pos - Double(base))
            let i0 = min(base, inFrames - 1)
            let i1 = min(base + 1, inFrames - 1)
            let l0 = frames[i0 * 2],     r0 = frames[i0 * 2 + 1]
            let l1 = frames[i1 * 2],     r1 = frames[i1 * 2 + 1]
            out[i * 2]     = l0 + (l1 - l0) * frac
            out[i * 2 + 1] = r0 + (r1 - r0) * frac
            pos += step
        }
        return out
    }

    private func floatStereoToInt16Bytes(_ frames: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frames.count * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0 ..< frames.count {
                var f = frames[i]
                if f > 1.0 { f = 1.0 } else if f < -1.0 { f = -1.0 }
                dst[i] = Int16(f * 32_767)
            }
        }
        return out
    }

    // MARK: - 診断ファイル

    private func writeStatus() {
        guard let container = containerUrl
                ?? FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return
        }
        let text = """
        started=\(startedFlag ? 1 : 0)
        container=\(containerOk ? "ok" : "nil")
        fd=\(sendFd)
        appBuffers=\(appBuffers)
        micBuffers=\(micBuffers)
        videoBuffers=\(videoBuffers)
        inRate=\(Int(lastInRate))
        inCh=\(lastInCh)
        inFloat=\(lastInFloat ? 1 : 0)
        outChunks=\(outChunks)
        outBytes=\(outBytes)
        lastErrno=\(lastErrno)
        """
        let url = container.appendingPathComponent(statusName)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - ログ抑止

    private func logErrorOnce(_ message: String) {
        if errorCount < maxLoggedErrors {
            NSLog("[BroadcastExtension] %@", message)
            errorCount += 1
        }
    }
}
