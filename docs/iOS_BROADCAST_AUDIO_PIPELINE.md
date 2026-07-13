# iOS Broadcast Extension 音声パイプラインの実装知見

> iPhone/iPad の内部音声を Broadcast Upload Extension で取り込み、App Group の
> UNIX Domain Socket 経由でメインアプリへ渡し、Opus/UDP で Hub へ送るまでに
> 踏んだ落とし穴と対処。2026-07-14 に local-audio-sync で実機(TestFlight)
> 疎通・クリア再生まで確認済み。**他リポジトリでも再利用できる汎用知見**。

経路の全体像:

```
Broadcast Upload Extension (SampleHandler, 別プロセス)
  │  .audioApp を CMSampleBuffer で受信
  │  AVAudioConverter で 48kHz/Int16/ステレオ/インターリーブへ正規化
  │  AF_UNIX SOCK_DGRAM で App Group コンテナのソケットへ sendto
  ▼
メインアプリ (BroadcastReceiverPlugin)
  │  同ソケットを bind して recvfrom → EventChannel
  ▼
Dart (ScreenAudioCaptureService → ClientController)
  │  PcmChunker で 20ms(3840B)化 → Opus エンコード → UDP
  ▼
Hub(集約・再生)
```

## 症状別・5 つの落とし穴と対処

### 1. 配信ボタンが押せない(`RPSystemBroadcastPickerView` の UiKitView 埋め込み)

`RPSystemBroadcastPickerView` を `UiKitView` として Flutter に埋め込む方式は、
**iOS 18/26 で内部の UIButton が描画されない・タップが伝搬しない**。ユーザーに
は「ボタンが無い/押せない、テキストしか無い」状態になる。

**対処**: 埋め込みをやめ、**通常の Flutter ボタン →(MethodChannel)→ ネイティブ
でピッカーをプログラム起動**する。ネイティブでキーウィンドウにほぼ不可視
(`alpha=0.01`・画面外)で `RPSystemBroadcastPickerView` を追加し、内部 UIButton を
再帰探索して `sendActions(for: .touchUpInside)` を送ればシステム配信シートが開く。
描画・タップ判定は Flutter 側で完結するため確実に動く。

### 2. `.audioApp` は 44100Hz で来ることがある(48kHz 決め打ちの罠)

`.audioApp` の CMSampleBuffer は端末・再生元によって **44100Hz** で来る。48000Hz
以外を無言でスキップする実装だと **1 フレームも送れず完全無音**になる(VU も
Hub もゼロ)。ASBD の `mSampleRate` を必ず確認し、任意レートを 48kHz へ変換する。

### 3. App Group の AF_UNIX データグラムは 1 通 2048 byte 上限(EMSGSIZE)

iOS/Darwin の `AF_UNIX SOCK_DGRAM` は 1 データグラム最大長が sysctl
`net.local.dgram.maxdgram`(**既定 2048 byte**)に制限され、超えると `sendto` が
**errno=40(EMSGSIZE)** で失敗し 1 バイトも届かない。アプリサンドボックスから
sysctl は変えられないので、**送信を 1024 byte 程度**(4 byte 境界=ステレオ Int16
のサンプル境界)に分割する。受信側は複数データグラムを結合して 20ms 化すればよい。

### 4. 受信リスナは「常時稼働・自己修復」にする

iOS では Extension が配信を続ける一方、メインアプリの受信(UDS bind + recvfrom
ループ)は Hub 接続とは独立。受信を「接続時に一度だけ起動」する設計だと、切断・
Hub 切替などで一度止まると**二度と再起動されず「接続しても音が来ない/たまに
しか来ない」**になる。受信側が居ないと Extension の `sendto` は
**errno=61(ECONNREFUSED)** を返す(→ fd を閉じてしまいさらに悪化)。

**対処**:
- 受信起動を冪等化(稼働中なら何もしない)し、接続時に必ず呼んで復帰させる。
- 通常の切断・一時停止・Hub 切替では**受信を止めない**(送信は接続状態ゲートで
  抑止)。完全停止は画面離脱時のみ。
- 毎秒ポーリングで「受信が止まっていたら再起動」する最終防波堤を置く。

### 5. 音声フォーマット変換は手書きせず AVAudioConverter に委ねる

手書きで Int16↔Float 変換・インターリーブ/プレーナ判定・線形リサンプルを
行うと、**planar/interleaved の取り違え**や**補間アーティファクト**で「ザー」と
いうホワイトノイズが乗り歪む。iOS 標準の **`AVAudioConverter`** に置き換えると
一掃できる。手順:

1. `CMSampleBufferGetFormatDescription` → `CMAudioFormatDescriptionGetStreamBasicDescription`
   で ASBD を取得し、`AVAudioFormat(streamDescription:)` で入力フォーマットを作る。
2. 出力は `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
   channels: 2, interleaved: true)`。
3. `AVAudioConverter(from:to:)` を**入力フォーマット単位でキャッシュ**(毎回作らない)。
4. `CMSampleBufferCopyPCMDataIntoAudioBufferList` で入力 PCM を
   `AVAudioPCMBuffer(pcmFormat: inFormat, ...)` の ABL へコピー。
5. `converter.convert(to:error:withInputFrom:)` で変換。入力ブロックは 1 回だけ
   `.haveData` を返し、以降 `.noDataNow`。
6. インターリーブ出力なので `audioBufferList.pointee.mBuffers.mData` に
   `[L R L R ...]` が入る。**バイト数は `frameLength * 4` から算出**(`mDataByteSize`
   は容量値が残る場合があり信頼しない)。

## 診断計装(Xcode コンソール無しで原因を確定する)

実機の Extension ログは通常見えない。**Extension が App Group コンテナに状態
テキストファイル(`broadcast_status.txt`)を定期書き出しし、メインアプリが読んで
UI 表示**する計装が極めて有効。無音時に一発で切り分けられた。記録項目の例:

```
started / container(ok|nil) / fd
appBuffers / micBuffers / videoBuffers   # .audioApp が来ているか
inRate / inCh / inFloat / inItlv          # 実際の入力フォーマット
outChunks / outBytes / lastErrno          # 送信できているか・失敗理由
app_recv(listening|stopped) / app_sinceData  # 受信側の生死(アプリ側で付記)
```

判定早見表:
- `appBuffers=0` → 音が鳴っていない / Extension 未起動。
- `appBuffers` 増 + `outBytes=0` + `lastErrno=40` → **EMSGSIZE**(#3)。
- `appBuffers` 増 + `outBytes=0` + `lastErrno=61` + `app_recv=stopped` → **受信停止**(#4)。
- `outBytes` 増 + `app_recv=listening` + `sinceData≈0` なのに音がおかしい → **変換**(#5)。

## 音量について(仕様)

iOS の `.audioApp` は**システム音量に関係なくフルスケール(0dBFS 付近)**で届く。
Windows ループバック(システム音量後)等より明らかに大きくなるが、これは仕様差
であって不具合ではない。**Hub 側の per-client 音量で調整**する運用にする。
