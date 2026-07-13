import ReplayKit
import AVFoundation
import Darwin

/// Broadcast Upload Extension の本体。
///
/// ReplayKit から渡される CMSampleBuffer のうち `audioApp`(他アプリも含む
/// デバイス全体の出力音声)を取り出し、**AVAudioConverter で 48kHz / PCM16 /
/// ステレオ / インターリーブへ正しく変換**して、App Group コンテナ内の UNIX
/// Domain Socket(SOCK_DGRAM)経由でメインアプリへ転送する。
///
/// 以前は手書きで Int16↔Float 変換・インターリーブ判定・線形リサンプルを
/// 行っていたが、planar/interleaved の取り違えや補間アーティファクトで
/// 「ザー」というノイズが乗っていた。iOS 標準の AVAudioConverter に委ねることで
/// 任意の入力フォーマット(44100Hz Int16 など)を高品質に正規化する。
///
/// 50MB のメモリ制限があるため、Opus エンコードや UDP 送信などの重い処理は
/// 行わず、フォーマット正規化と UDS 転送のみに専念する。
///
/// 診断: App Group コンテナに `broadcast_status.txt` を定期的に書き出す。
@objc(SampleHandler)
class SampleHandler: RPBroadcastSampleHandler {

    /// App Group 識別子(メインアプリと同じ値にする)。
    private let appGroupId = "group.com.roto0504.localAudioSync"

    /// ソケットファイル名(コンテナ直下に配置)。
    private let socketName = "audio.sock"

    /// 診断ファイル名。
    private let statusName = "broadcast_status.txt"

    /// 出力フォーマット(メインアプリ / Opus パイプラインの前提):
    /// 48kHz / Int16 / ステレオ / インターリーブ。
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    /// 入力フォーマット→出力フォーマットのコンバータ(入力形式が変わるまで使い回す)。
    private var converter: AVAudioConverter?
    private var converterInFormat: AVAudioFormat?

    /// 送信用ソケット FD。生成失敗時は -1。
    private var sendFd: Int32 = -1

    /// 接続先のソケットアドレス。
    private var serverAddr = sockaddr_un()

    /// コンテナ URL(診断ファイル書き込みにも使う)。
    private var containerUrl: URL?

    /// 一度の送信(1 データグラム)で扱う最大バイト数。
    ///
    /// iOS/Darwin の AF_UNIX SOCK_DGRAM は 1 データグラムの最大長が
    /// `net.local.dgram.maxdgram`(既定 2048 byte)に制限される。これを超えると
    /// `sendto` が errno=40(EMSGSIZE)で失敗し、1 バイトも届かない。
    /// 余裕を持って 1024 byte(= ステレオ 256 サンプル分、4 byte 境界)に刻む。
    private let maxChunkBytes = 1024

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
    private var lastInInterleaved = false
    private var lastErrno: Int32 = 0
    private var startedFlag = false
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

        // 小さいデータグラムを多数送るので送信バッファを広げておく。
        var sndBuf: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

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

    // MARK: - 音声バッファ送信(AVAudioConverter で正規化)

    private func sendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return
        }

        lastInRate = asbd.pointee.mSampleRate
        lastInCh = Int(asbd.pointee.mChannelsPerFrame)
        lastInFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        lastInInterleaved =
            (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // 入力 AVAudioFormat を ASBD から生成
        guard let inFormat = AVAudioFormat(streamDescription: asbd) else {
            logErrorOnce("入力フォーマット生成失敗")
            return
        }

        // コンバータをキャッシュ(入力フォーマットが変わったら作り直す)
        if converter == nil || converterInFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converterInFormat = inFormat
        }
        guard let converter = converter else {
            logErrorOnce("コンバータ生成失敗")
            return
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat,
                frameCapacity: AVAudioFrameCount(numSamples)
              ) else {
            return
        }
        inBuffer.frameLength = AVAudioFrameCount(numSamples)

        // CMSampleBuffer の PCM を入力バッファの AudioBufferList へコピー
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            logErrorOnce("CMSampleBufferCopyPCMData 失敗: \(copyStatus)")
            return
        }

        // 出力バッファ(リサンプルで増える分の余裕を持たせる)
        let outCapacity = AVAudioFrameCount(
            Double(numSamples) * outFormat.sampleRate / inFormat.sampleRate
        ) + 32
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: outCapacity
        ) else {
            return
        }

        var error: NSError?
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            logErrorOnce("convert 失敗: \(String(describing: error))")
            return
        }
        guard outBuffer.frameLength > 0 else { return }

        // インターリーブ出力なので mBuffers[0] に [L R L R ...] が詰まっている。
        // バイト数は frameLength から算出する(mDataByteSize は容量値が残る場合が
        // あるため信頼しない)。ステレオ Int16 = 4 byte/フレーム。
        let audioBuffer = outBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        let dataSize = Int(outBuffer.frameLength) * 4
        guard dataSize > 0, dataSize <= Int(audioBuffer.mDataByteSize) else { return }

        var bytes = [UInt8](repeating: 0, count: dataSize)
        bytes.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!, mData, dataSize)
        }

        // チャンク分割(ステレオ 1 サンプル = 4 byte 境界を維持)して送信
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let chunkLen = min(remaining, maxChunkBytes)
            let aligned = chunkLen - (chunkLen % 4)
            if aligned <= 0 { break }
            let chunk = Array(bytes[offset ..< (offset + aligned)])
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
        inItlv=\(lastInInterleaved ? 1 : 0)
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
