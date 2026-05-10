import AVFoundation
import Foundation

/// メインアプリ側の `AVAudioSession` を一元管理するシングルトン。
///
/// 旧実装では `AppDelegate` と `ScreenAudioPlugin` が別々に `setCategory` /
/// `setActive` を呼んでいたため、設定が衝突して iPad で不安定な挙動を起こすことが
/// あった。本クラスでは設定を 1 か所に集約し、配信開始/終了に応じて明示的に
/// `activate()` / `deactivate()` を呼ぶ。
///
/// 新方針(内部音声のみ・マイク不要)では:
///
/// - カテゴリは `.playback`(マイク権限不要、他アプリの音を邪魔しない)
/// - オプションは `.mixWithOthers`(BGM などと共存)
/// - silent loop は「メインアプリがバックグラウンドに居ても UDP 送信を続けたい」
///   という背景維持目的で再生する。0.0 ボリューム + 数秒ループ。
/// - 配信中は `.playback` を活性化、配信を完全に止めたら deactivate。
final class AudioSessionManager {

    static let shared = AudioSessionManager()

    private let queue = DispatchQueue(label: "com.example.local_audio_sync.audioSession")
    private var silentPlayer: AVAudioPlayer?
    private var activated = false

    private init() {}

    // MARK: - Public API

    /// 音声配信開始時に呼ぶ。バックグラウンド維持用の silent loop 再生も開始する。
    /// 二重呼び出しは安全(冪等)。
    func activate() {
        queue.sync {
            if activated { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
                try session.setActive(true, options: [])
            } catch {
                NSLog("[AudioSessionManager] setCategory/setActive 失敗: \(error)")
                return
            }
            startSilentLoop()
            activated = true
        }
    }

    /// 配信を完全に止めるときに呼ぶ。silent loop も停止し、セッションを解放する。
    func deactivate() {
        queue.sync {
            if !activated { return }
            stopSilentLoop()
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
            } catch {
                NSLog("[AudioSessionManager] setActive(false) 失敗: \(error)")
            }
            activated = false
        }
    }

    /// 現在 active か。
    var isActivated: Bool {
        return queue.sync { activated }
    }

    // MARK: - Silent loop

    /// 0 ボリュームの極短 WAV を無限ループで鳴らし、`audio` バックグラウンドモードを
    /// 維持する。再生に失敗してもクラッシュしないよう例外を握る。
    private func startSilentLoop() {
        guard silentPlayer == nil else { return }
        let wavData = makeSilentWavData(durationSeconds: 1.0, sampleRate: 44_100)
        do {
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.0
            // 無条件 prepareToPlay すると iPad で稀に AVAudioPlayer が
            // 内部状態を壊すことがあるので明示的に呼ばない。play() で十分。
            if player.play() {
                silentPlayer = player
            } else {
                NSLog("[AudioSessionManager] silentPlayer.play() が false を返した")
                silentPlayer = nil
            }
        } catch {
            NSLog("[AudioSessionManager] silentPlayer 生成失敗: \(error)")
            silentPlayer = nil
        }
    }

    private func stopSilentLoop() {
        if let player = silentPlayer {
            player.stop()
        }
        silentPlayer = nil
    }

    // MARK: - WAV 生成

    /// PCM16 モノラル無音の WAV データを生成する。
    private func makeSilentWavData(durationSeconds: Double,
                                    sampleRate: Int) -> Data {
        let totalSamples = Int(Double(sampleRate) * durationSeconds)
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(totalSamples) * UInt32(blockAlign)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(toLE32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(toLE32(16))                   // chunk size
        data.append(toLE16(1))                    // PCM
        data.append(toLE16(channels))
        data.append(toLE32(UInt32(sampleRate)))
        data.append(toLE32(byteRate))
        data.append(toLE16(blockAlign))
        data.append(toLE16(bitsPerSample))
        data.append(contentsOf: "data".utf8)
        data.append(toLE32(dataSize))
        data.append(Data(count: Int(dataSize)))   // 全サンプル 0
        return data
    }

    private func toLE16(_ v: UInt16) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private func toLE32(_ v: UInt32) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
