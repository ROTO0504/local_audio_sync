# iOS 配信(Broadcast Extension)完全ガイド — まずここを読む

> iPhone / iPad の**内部音声**を取り込み、LAN 上の Hub へ配信する iOS 実装の
> 入口ドキュメント。ここに**全体像・再現手順・つまずきポイントの早見表**を集約し、
> 詳細は個別ドキュメントへリンクする。**別の担当者がゼロから触っても同じ問題を
> 踏まないこと**を目的とする。2026-07-14、実機(TestFlight)でクリア再生まで確認済み。

## この機能が実際に動いた状態(ゴール)

- クライアント画面に全幅ボタン「**タップして配信を開始**」が出る
- 押すと iOS のシステム配信シートが開き、「**Local Audio Sync**」を選んで開始
- iPhone で再生中の音(YouTube・音楽など)が **Hub からクリアに再生**される
- クライアント画面の「配信診断」で `outBytes` が増え続け、`lastErrno=0`、
  `app_recv=listening`、`app_sinceData≈0.0s`

---

## 1. アーキテクチャ(なぜ多段なのか)

iOS は Apple の制約で「他アプリ音声のプログラム取得」ができず、**Broadcast Upload
Extension**(別プロセス)経由でしか内部音声を取れない。Extension はメモリ 50MB 制限が
あるため重い処理はできない。そこで **Extension は変換と転送だけ**を行い、Opus/UDP は
メインアプリが担う:

```
┌─ Broadcast Upload Extension(別プロセス / SampleHandler.swift)
│    .audioApp(他アプリ含むデバイス音声)を CMSampleBuffer で受信
│    AVAudioConverter で 48kHz / Int16 / ステレオ / インターリーブへ正規化
│    App Group コンテナの AF_UNIX SOCK_DGRAM へ sendto(1 通 ≤1024B)
▼
┌─ メインアプリ(Runner / BroadcastReceiverPlugin.swift)
│    同ソケットを bind → recvfrom ループ → EventChannel で Dart へ
▼
┌─ Dart(ScreenAudioCaptureService → ClientController)
│    PcmChunker で 20ms(3840B)化 → Opus エンコード → UDP 送信
▼
└─ Hub(集約・再生)
```

**要点**: Extension とメインアプリは**別プロセス**で、App Group の共有コンテナに
置いた UNIX Domain Socket でだけ繋がる。両者の App Group ID が一致しないと無音になる。

---

## 2. 再現手順(2 ルート)

### ルート A: Mac + Xcode がある

→ [setup-xcode.md](setup-xcode.md) の手順で Xcode から Extension
ターゲットを追加し、App Groups を有効化して実機ビルド。ローカル実機テスト(Apple ID
署名)は API キー不要で手軽。

### ルート B: Mac/Xcode が手元に無い(Windows など)+ CI/TestFlight で配信

→ [setup-no-xcode-pbxproj.md](setup-no-xcode-pbxproj.md) の手順で
`xcodeproj` gem を macOS CI 上で実行して Extension ターゲットを `project.pbxproj` へ
プログラム的に追加し、fastlane + Spaceship で署名資産を用意して**手動署名**で
TestFlight へ上げる。**このリポジトリは実際にこのルートで通した。**

どちらのルートでも、**実行時の音声パイプライン**で踏む問題は共通 →
[audio-pipeline.md](audio-pipeline.md)。

---

## 3. つまずきポイント早見表(症状 → 原因 → 対処)

過去に実際に踏んで解決した順。**新しい担当者はまずこの表を見れば原因に一直線で辿れる。**

| # | 症状 | 決め手・診断値 | 原因 | 対処 | 詳細 |
|---|---|---|---|---|---|
| 1 | Extension を用意したのに配信ボタンを押しても Picker に出ない | `project.pbxproj` に `app-extension` productType が無い | Extension が **Xcode ターゲット未登録**でアプリに同梱されていない | ターゲットを追加(ルート A/B) | PBXPROJ 参照 |
| 2 | Extension のコピーで `Cycle inside Runner` ビルド失敗 | 新ビルドシステムのエラー | 「Embed App Extensions」が **Thin Binary より後ろ** | Embed フェーズを **Thin Binary の前**に挿入 | PBXPROJ 参照 |
| 3 | archive で `No profiles for '...BroadcastExtension'` | 手動署名でプロファイル無し | Extension 用プロビジョニングプロファイル未作成 | fastlane `sigh` で作成(手動署名) | PBXPROJ 参照 |
| 4 | `-allowProvisioningUpdates` が `Authentication failed: bearer token` | xcodebuild 内部の自動プロビジョニング認証だけ失敗 | Extension の新規 App ID 作成に xcodebuild 自動プロビジョニングは通らない | **fastlane + Spaceship** で App ID/プロファイルを事前作成し**手動署名** | PBXPROJ 参照 |
| 5 | `Provisioning profile doesn't support the ... App Group` | App Group 関連付けエラー | App Group の**特定グループ関連付け**は ASC API 非対応(ポータル専用) | Developer ポータルで該当 Bundle ID → App Groups を Edit → チェック→Save の**1 回だけ手作業** | PBXPROJ 参照 |
| 6 | 配信ボタンが押せない / 文字だけでボタンが無い | — | `RPSystemBroadcastPickerView` の **UiKitView 埋め込み**は iOS 18/26 で描画/タップ不能 | 通常の Flutter ボタン→MethodChannel で**ピッカーをプログラム起動** | AUDIO_PIPELINE #1 |
| 7 | VU も Hub 音声も**完全ゼロ** | 診断 `appBuffers=0` | 音が鳴っていない or Extension 未起動 | 端末で音を再生。Extension 同梱を確認 | AUDIO_PIPELINE |
| 8 | 音がゼロ、`.audioApp` は来ている | `appBuffers` 増 / `inRate=44100` | Extension が **48000Hz 決め打ち**で 44100 を全スキップ | 任意レートを **48kHz へ変換**(AVAudioConverter) | AUDIO_PIPELINE #2 |
| 9 | 音がゼロ | 診断 `outBytes=0` / `lastErrno=40` | **EMSGSIZE**。App Group UDS は 1 通 **2048B 上限**なのに 8192B 送信 | 送信を **1024B に分割** | AUDIO_PIPELINE #3 |
| 10 | 繋がったり繋がらなかったり | 診断 `app_recv=stopped` / `lastErrno=61`(ECONNREFUSED) | 受信リスナが**一度止まると再起動されない** | 受信を**常時稼働・自己修復**(接続時に必ず起動+毎秒ポーリングで復帰) | AUDIO_PIPELINE #4 |
| 11 | 音は出るが「ザー」というノイズ・歪み | 変換以外は正常(`outBytes` 増) | 手書きの Int16↔Float / interleave 判定 / 線形リサンプルのアーティファクト | **AVAudioConverter** に置換 | AUDIO_PIPELINE #5 |
| 12 | 音が大きすぎる | 波形はクリア | `.audioApp` は**システム音量と無関係にフルスケール**で来る(仕様) | Hub 側の per-client 音量スライダーで調整 | AUDIO_PIPELINE |

**errno 早見(Darwin/iOS)**: `40 = EMSGSIZE`(データグラム過大 → #9)、
`61 = ECONNREFUSED`(受信側不在 → #10)。

---

## 4. 実機での自己診断(Xcode コンソール不要)

実機の Extension ログは通常見えないため、**Extension が App Group に
`broadcast_status.txt` を定期書き出し**し、メインアプリが読んでクライアント画面の
「配信診断」に表示する計装を入れてある。無音時はまずこれを見る:

```
started=1            # Extension が起動したか
container=ok         # App Group コンテナを取れたか(nil なら entitlement 不一致)
fd=3                 # 送信ソケット(-1 は生成失敗 or ECONNREFUSED で閉じた)
appBuffers=1125      # .audioApp が届いた数(0 なら音が鳴ってない/未起動)
inRate=44100         # 実際の入力サンプルレート
inCh=2  inFloat=0  inItlv=1   # チャンネル/浮動小数/インターリーブ
outChunks=6249  outBytes=..   # アプリへ送れた量(0 なら送信失敗)
lastErrno=0          # 直近の送信エラー(40/61 は上の早見表へ)
app_recv=listening   # メインアプリの受信ループの生死
app_sinceData=0.0s   # 最終受信からの経過(増え続けるなら受信が途絶)
```

---

## 5. 固定値・前提(変更時は両側を揃える)

- **App Group ID**: `group.com.roto0504.localAudioSync`
  (`Runner.entitlements` / `BroadcastExtension.entitlements` / 両 Swift の `appGroupId`)
- **Extension Bundle ID**: `com.roto0504.localAudioSync.BroadcastExtension`
- **ソケット名**: `audio.sock`(App Group コンテナ直下)
- **出力音声フォーマット**: 48kHz / PCM16 / ステレオ / インターリーブ(Opus 前提)
- **UDS 1 データグラム上限**: 2048B(`net.local.dgram.maxdgram`、サンドボックスから変更不可)
- **mDNS サービス名**: `_lasync._udp`(RFC の 15 文字制限。Info.plist の NSBonjourServices と Dart を一致させる)
- **以降の配信**: App Group 関連付け済みなら `gh workflow run testflight.yml -f platform=ios` だけで全自動

---

## 6. 取得できないもの(iOS 仕様・対処不可)

- **DRM 音声**(Apple Music / Netflix / Amazon Prime Video 等)は画面ブロードキャスト
  でも音声が落ちる。取得不可。
- メインアプリを**スワイプ完全終了**すると UDP 送信元が消えて Hub に届かない。
  配信中はメインアプリを起動したままにする。

---

## 関連ドキュメント

- [setup-xcode.md](setup-xcode.md) — Mac/Xcode でのターゲット追加・App Groups
- [setup-no-xcode-pbxproj.md](setup-no-xcode-pbxproj.md) — Xcode 無しでのターゲット追加(xcodeproj gem)・TestFlight 手動署名
- [audio-pipeline.md](audio-pipeline.md) — 実行時の音声パイプライン 5 大落とし穴・診断計装
