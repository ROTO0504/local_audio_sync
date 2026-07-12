# local-audio-sync

ローカルネットワーク(LAN)上の **複数デバイスで再生されている内部音声**(他アプリの音 = Spotify / YouTube / ゲーム等)を、Wi-Fi 経由で 1 台の **Hub** に集約してまとめて再生するアプリです。

**Hub(集約・再生側)も Client(送信側)も、iPhone / iPad / Android / macOS / Windows のどの端末でも動きます。** それぞれの OS のネイティブ API で内部音声をキャプチャし、Opus で圧縮した音声を UDP で Hub へ送信します。Hub 側は miniaudio ベースのネイティブミキサーで全クライアントをミックス再生します。

> **マイク機能は廃止しました**(2026-05-10)。集めるのは「他アプリの音」だけです。
> 全体計画は [docs/PLAN.md](docs/PLAN.md)(v1)/ [plan/2026-07-12.md](plan/2026-07-12.md)(v2)を参照。

---

## 目次

1. [できること / できないこと](#できること--できないこと)
2. [全体アーキテクチャ](#全体アーキテクチャ)
3. [動作要件](#動作要件)
4. [セットアップ手順](#セットアップ手順)
5. [使い方](#使い方)
6. [ネットワーク越え(VPN / 別セグメント)](#ネットワーク越えvpn--別セグメント)
7. [プラットフォーム別の内部音声キャプチャ詳細](#プラットフォーム別の内部音声キャプチャ詳細)
8. [通信プロトコル詳細](#通信プロトコル詳細)
9. [プロジェクト構造](#プロジェクト構造)
10. [ビルド方法](#ビルド方法)
11. [テスト](#テスト)
12. [CI/CD](#cicd)
13. [トラブルシューティング](#トラブルシューティング)

---

## できること / できないこと

### できること

- iPhone / iPad / macOS / Windows / Android で再生している **他アプリの音声** を取得
- **どの端末でも Hub(集約・再生)になれる**(miniaudio ミキサーを全 OS でビルド)
- 各クライアントごとに音量調整 / ミュート(**設定はデバイス ID 単位で永続化**され、再接続時に復元)
- **Hub からクライアントの配信をリモート操作**(一時停止 / 再開 / 停止、全員一括も可)
- 自動探索(mDNS/Bonjour + UDP ビーコンのデュアルスタック)
- **手動 IP 接続**(ブロードキャストが届かないセグメントや VPN 経由用、履歴つき)
- 受信バッファの遅延プリセット切替(LAN 低遅延 / WAN 安定重視)
- Hub 喪失時の自動再探索、PONG 途絶検出、UDP ソケット死亡時の自動再生成
- 同期ずれ時の自動再同期(JitterBuffer 内蔵)

### できないこと

| 制限 | 理由 |
| --- | --- |
| マイクの音声を送る | 用途を内部音声に絞ったため(2026-05-10 仕様確定) |
| Apple Music / Netflix / Amazon Prime Video など DRM 保護コンテンツの音声を取得 | iOS / Android / macOS の OS 仕様で取得不可 |
| 裸のインターネット直結(NAT 越え) | 平文 UDP のため非対応。**VPN(Tailscale 等)経由なら WAN でも利用可**(後述) |
| クライアント端末上の音楽アプリ自体の再生/停止操作 | OS 制約(リモート制御の対象は「配信ストリーム」のみ) |
| iOS Hub 側からの Broadcast Extension 完全停止 | iOS の Picker 制約。リモート STOP は送信停止のみ保証 |

---

## 全体アーキテクチャ

```text
┌──────────────────────────────────────────────────────────────────┐
│  クライアント(送信側)— 全 OS                                     │
│                                                                  │
│  [OS 別の内部音声キャプチャ]                                      │
│   - iOS / iPadOS: Broadcast Upload Extension(別プロセス)        │
│       └ App Group 共有 UNIX Domain Socket → メインアプリ         │
│   - Android: MediaProjection + AudioPlaybackCaptureConfiguration │
│   - macOS: ScreenCaptureKit + SCStream(capturesAudio = true)     │
│   - Windows: WASAPI loopback(audio_mixer_plugin.dll)             │
│                                                                  │
│  ↓ PCM16 / 48kHz / ステレオ / 20ms フレーム                       │
│  Opus エンコード(128 kbps)                                       │
│  ↓                                                               │
│  UDP ユニキャスト(ポート 7777)                                  │
│  ＋ CMD 受信(PAUSE/RESUME/STOP)→ 送信ゲート制御                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  Hub(集約・再生側)— ★全 OS 対応                                 │
│                                                                  │
│  UDP 受信 → クライアントごとのジッターバッファ(LAN/WAN プリセット)│
│  → Opus デコード(PLC 対応)                                       │
│  → 個別音量調整(デバイス ID 単位で永続化)                        │
│  → miniaudio ミキサー(FFI プラグイン: Win/mac/iOS/Android)       │
│  → スピーカー出力                                                 │
│                                                                  │
│  ＋ CMD 送信(リモート制御、CMDACK まで自動再送)                  │
│  ＋ Android: mediaPlayback FGS / iOS: AVAudioSession(.playback)   │
└──────────────────────────────────────────────────────────────────┘
```

### 自動検出(ディスカバリー、デュアルスタック)

| 方式 | 内容 |
| --- | --- |
| **mDNS / Bonjour** | Hub がサービス型 `_lasync._udp` を公開、クライアントがブラウズ。**iOS Hub はこれが唯一の被発見手段**(iOS はブロードキャスト送信に multicast entitlement が必要なため) |
| **UDP ビーコン** | Hub が 2 秒ごとにポート **9999** へブロードキャスト(v1/v2 併送)。旧バージョン互換 + mDNS が使えない環境の保険 |
| **手動 IP 接続** | クライアント画面の「手動接続」から `IP:ポート` を直接入力(履歴 5 件保存) |

- クライアントは **6 秒間ビーコン未受信** → 「Hub 喪失」と判定 → 自動的に再探索状態へ復帰
- v2 Hub 相手では **PING への PONG 応答**も監視し、15 秒途絶で再接続(ハング検出)
- **UDP 送信失敗** → ソケット再生成 + 指数バックオフ再接続(最大 5 秒間隔)

---

## 動作要件

| プラットフォーム | バージョン要件 | 備考 |
| --- | --- | --- |
| Windows(Hub / Client) | Windows 10 以降(x64) | Visual Studio 2022 Build Tools |
| iOS / iPadOS(Hub / Client) | iOS 14 以降 | Client には Broadcast Upload Extension が必要 |
| macOS(Hub / Client) | **macOS 13 以降**(ScreenCaptureKit 要件) | Client には画面録画許可が必要 |
| Android(Hub / Client) | API 29(Android 10)以降 | Client には MediaProjection 要件 |
| Flutter SDK | 3.24 以降 | |
| Dart SDK | 3.5 以降 | |

**全デバイスが同一 LAN(Wi-Fi / 有線)に接続している必要があります**(VPN 経由の利用は[こちら](#ネットワーク越えvpn--別セグメント))。

---

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone <repository-url>
cd local-audio-sync
```

### 2. 依存パッケージのインストール

```bash
flutter pub get
```

### 3. iOS / iPadOS の追加セットアップ

iOS / iPadOS で他アプリの音を取るには、Xcode 上で **Broadcast Upload Extension ターゲット** を手動で追加する必要があります(Hub として使うだけなら不要)。詳細手順:

→ [docs/iOS_BROADCAST_SETUP.md](docs/iOS_BROADCAST_SETUP.md)

### 4. macOS の追加セットアップ

クライアントとして使う場合、初回起動時に「画面録画」の許可ダイアログが OS から表示されます。許可してください。

```text
システム設定 → プライバシーとセキュリティ → 画面録画 → local_audio_sync をオン
```

### 5. Windows のビルド準備(初回のみ)

Visual Studio 2022 Build Tools(C++ ワークロード)が必要です。

<https://visualstudio.microsoft.com/ja/downloads/#build-tools-for-visual-studio-2022>

### 6. Android の追加セットアップ

設定済みの `AndroidManifest.xml` でパーミッションが宣言されています。クライアントとして使う場合、初回起動時に「画面のキャストとオーディオの記録」許可ダイアログが出るので許可してください。

---

## 使い方

### 起動

```bash
# Windows
flutter run -d windows

# Android(USB 接続デバイス)
flutter run -d android

# iOS / iPadOS(USB 接続デバイス)
flutter run -d ios

# macOS
flutter run -d macos
```

### Hub(集約・再生側)の使い方

1. アプリ起動 → 初期画面で **「Hub(集約・再生)」** を選択(どの端末でも OK)
2. デバイス名を入力して起動すると、mDNS 公開とビーコン送信が始まります
3. ヘッダに **自分の IP:ポート** が表示されます(手動接続の案内用)
4. クライアントが接続すると一覧に表示されます:
   - **音量スライダー / ミュート** — デバイスごとに調整(再接続後も記憶)
   - **⏸ / ▶ ボタン** — そのクライアントの配信をリモートで一時停止 / 再開
   - **VU メーター** — 受信中の音声レベル
   - プラットフォームアイコン / デバイス ID / 接続状態バッジ
5. ヘッダの **マスター音量** で全体を一括調整、**⏸/▶** で全員一括停止・再開
6. 設定(⚙)から **受信バッファのプリセット**(LAN 低遅延 / WAN 安定)を切替可能

### クライアント(送信側)の使い方

1. アプリ起動 → 初期画面で **「クライアント(送信)」** を選択
2. デバイス名を入力して起動すると、LAN 上の Hub を自動検索(mDNS + ビーコン)
3. Hub が見つかると自動接続
4. **配信開始**:
   - **iOS / iPadOS**: 画面の **「タップして配信開始」** ボタンをタップ → システムシートで「Local Audio Sync 配信」を選択 → **ブロードキャストを開始**
   - **Android**: 画面のキャプチャ許可ダイアログが出るので許可
   - **macOS**: 自動でキャプチャ開始(画面録画許可は事前に承認しておく)
   - **Windows**: 自動でキャプチャ開始(デフォルト出力デバイスをループバック)
5. 配信中は VU メーターが反応します
6. Hub から一時停止された場合は **「Hub により配信が一時停止されています」** バナーが出ます(端末側から再開も可能)
7. 「Hub から切断」ボタンで停止

### 役割の切り替え

画面右上の **「⇄」** アイコンで役割選択画面に戻ります。選択したロールは次回起動時も保持されます。

---

## ネットワーク越え(VPN / 別セグメント)

ブロードキャスト / mDNS が届かないネットワークでは自動探索が使えませんが、**手動 IP 接続**で利用できます。

### 別セグメント(同一拠点の別サブネット等)

1. Hub 画面のヘッダに表示される `IP:ポート` を確認
2. クライアント画面右上の **「手動接続」**(⚡アイコン)から入力して接続

### WAN(インターネット越し)— VPN 推奨

平文 UDP を裸のインターネットに晒す運用は**非推奨**です。[Tailscale](https://tailscale.com/) / WireGuard などの VPN で端末同士を同一仮想ネットワークに入れてください。

1. Hub とクライアントの両端末に Tailscale をインストールし、同じアカウント(tailnet)にログイン
2. Hub 側の **Tailscale の IP(100.x.x.x)** を確認
3. クライアントの手動接続でその IP とポート 7777 を入力
4. Hub 設定で受信バッファを **「WAN / VPN(安定重視)」** に切り替えると、ジッタによる音切れが減ります(遅延は約 200ms に増加)

> 帯域はクライアント 1 台あたり約 130〜150 kbps(Opus 128kbps + ヘッダ)です。

---

## プラットフォーム別の内部音声キャプチャ詳細

| OS | 取得 API | 制約 |
| --- | --- | --- |
| **iOS / iPadOS** | Broadcast Upload Extension(ReplayKit) | DRM 不可、Extension メモリ 50MB、Picker UX 必須 |
| **Android** | MediaProjection + AudioPlaybackCaptureConfiguration(API 29+) | DRM 不可、対象アプリが `allowAudioPlaybackCapture` 許可必須 |
| **macOS** | ScreenCaptureKit + SCStream(macOS 13+) | 画面録画許可必須 |
| **Windows** | WASAPI loopback(`audio_mixer_plugin.dll` 経由) | デフォルト出力デバイスから取得 |

### Hub(再生側)のプラットフォーム対応

| OS | 再生 | バックグラウンド維持 |
| --- | --- | --- |
| **Windows** | miniaudio(WASAPI) | 不要(デスクトップ) |
| **macOS** | miniaudio(CoreAudio) | 不要(デスクトップ) |
| **Android** | miniaudio(AAudio / OpenSL) | mediaPlayback フォアグラウンドサービス |
| **iOS / iPadOS** | miniaudio(CoreAudio) | AVAudioSession(.playback)+ `UIBackgroundModes: audio` |

### iOS / iPadOS の詳細

- メインアプリ ↔ Extension 間は App Group コンテナ内の **UNIX Domain Socket(SOCK_DGRAM)** で PCM を転送
- Extension の 50MB メモリ制限を守るため、**エンコードや UDP 送信は Extension 側で行わず、メインアプリ側に集約**
- Extension の bundle ID(既定:`com.example.localAudioSync.BroadcastExtension`)はメインアプリ側の `client_screen.dart` で参照しているので、Xcode で Bundle ID を変えた場合は `_broadcastExtensionBundleId` 定数も更新

### Windows の詳細

- `audio_mixer_plugin.dll`(`packages/audio_mixer_ffi` でビルド)内の loopback API を Dart から FFI で叩く
- `loopback_start` → リングバッファに PCM16 を書き込み、Dart 側が 20ms 周期で polling
- ミキサーと同居する 1 つの DLL なので、Windows では **Hub と Client 兼務が可能**

---

## 通信プロトコル詳細

### ディスカバリー

#### mDNS / Bonjour

- サービスタイプ: `_lasync._udp`(RFC 6335 の 15 文字制限に収めた短縮名)
- TXT レコード: `name`(Hub 表示名)/ `hubId`(Hub の永続 UUID)/ `proto`(プロトコルバージョン)

#### ビーコン(UDP ブロードキャスト、ポート 9999)

Hub が 2 秒ごとに `255.255.255.255` へ v2 → v1 の順に併送するテキスト:

```text
LAHUB2:{hubIPv4}:7777:{hubName}:{hubId}:2   ← v2(新クライアント向け)
LAHUB:{hubIPv4}:7777:{hubName}              ← v1(旧クライアント互換)
```

クライアント側は **6 秒間** 受信が無いと「喪失」とみなして再探索に戻ります。

### 音声パケット(UDP ユニキャスト、ポート 7777)

| オフセット | サイズ | 内容 |
| --- | --- | --- |
| 0 | 2 byte | マジックバイト: `0xA1 0xA2` |
| 2 | 2 byte | クライアント ID(uint16、ビッグエンディアン) |
| 4 | 4 byte | シーケンス番号(uint32、ビッグエンディアン) |
| 8 | 可変 | Opus ペイロード(20ms フレーム、約 80〜320 byte) |

### 制御メッセージ(テキスト、ポート 7777)

| メッセージ | 方向 | 形式 | 説明 |
| --- | --- | --- | --- |
| HELLO | C → H | `HELLO:{name}:{uuid}` | v1 接続開始(旧 Hub 互換のため v2 でも併送) |
| HELLO2 | C → H | `HELLO2:{name}:{uuid}:{platform}:{proto}` | v2 接続開始(platform = ios/android/macos/windows) |
| ACKHELLO | H → C | `ACKHELLO:{assignedId}` | ID 割り当て |
| PING | C → H | `PING:{clientId}` | 接続維持(5 秒ごと) |
| PONG | H → C | `PONG:{clientId}` | PING 応答。15 秒途絶で再接続トリガ(v2) |
| CMD | H → C | `CMD:{clientId}:{cmdSeq}:{PAUSE\|RESUME\|STOP}` | リモート制御。CMDACK まで 500ms × 最大 5 回再送 |
| CMDACK | C → H | `CMDACK:{clientId}:{cmdSeq}` | CMD 到達確認。同一 cmdSeq は再実行しない |
| RESYNC | H → C | `RESYNC:{clientId}` | seq リセット要求(ジッターバッファ再同期) |
| BYE | C → H | `BYE:{clientId}` | 切断通知 |

- クライアントの `uuid` は**初回起動時に生成して永続化**されるデバイス ID。Hub はこれをキーに音量 / ミュート設定を記憶します。
- リモート制御の PAUSE は「送信ゲートを閉じる」動作(キャプチャは維持、帯域も止まる)。RESUME 時は seq を 0 に戻して自然に再同期します。

### 音声仕様

| 項目 | 値 |
| --- | --- |
| コーデック | Opus |
| サンプルレート | 48,000 Hz |
| チャンネル | 2(ステレオ) |
| ビットレート | 128 kbps |
| フレームサイズ | 20 ms(960 サンプル/チャンネル、3840 byte の PCM16) |
| ジッターバッファ | 固定遅延方式(LAN: 40ms / WAN: 200ms プリセット)+ **シーケンス乖離 100 フレーム以上で自動再同期** |

---

## プロジェクト構造

```text
local-audio-sync/
├── docs/
│   ├── PLAN.md                       # リアーキテクチャ計画(v1、実装済み)
│   └── iOS_BROADCAST_SETUP.md        # iOS Extension の Xcode セットアップ手順
├── plan/
│   ├── 2026-07-12.md                 # 機能拡張計画 v2(ユニバーサル Hub + リモート制御)
│   └── MAC_VSCODE_BUILD.md           # Mac での開発環境セットアップ
│
├── packages/audio_mixer_ffi/         # miniaudio ミキサー + Windows loopback(FFI プラグイン)
│   ├── src/                          # 共有 C++ ソース(audio_mixer.cpp / miniaudio.h)
│   ├── android/ + src/CMakeLists.txt # NDK ビルド(libaudio_mixer_plugin.so)
│   ├── ios/ / macos/                 # CocoaPods(Objective-C++ でコンパイル)
│   └── windows/CMakeLists.txt        # DLL ビルド(audio_mixer_plugin.dll)
│
├── lib/
│   ├── main.dart                     # エントリポイント(Opus 初期化 + ProviderScope)
│   ├── app.dart                      # GoRouter ルーティング + ja_JP ロケール
│   ├── models/
│   │   ├── app_mode.dart             # enum AppMode { hub, client }
│   │   ├── client_info.dart          # クライアント情報(IP / 音量 / 状態 / VU / 一時停止)
│   │   ├── control_messages.dart     # プロトコル v2 のパース / エンコード(HELLO2/CMD 等)
│   │   └── audio_packet.dart         # UDP パケットのシリアライザ
│   ├── providers/
│   │   ├── app_mode_provider.dart    # ロール状態(SharedPreferences で永続化)
│   │   ├── hub_state_provider.dart   # 接続クライアント一覧 + 音量
│   │   └── client_state_provider.dart # 接続状態 / VU レベル / Hub 一時停止
│   ├── services/
│   │   ├── hub_controller.dart       # Hub のコアロジック(受信・ミキサー・リモート制御)
│   │   ├── device_identity_service.dart # 永続デバイス ID(クライアント UUID / hubId)
│   │   ├── client_settings_store.dart   # デバイスごとの音量設定の永続化
│   │   ├── manual_hub_store.dart        # 手動接続の履歴
│   │   ├── command_retry_queue.dart     # CMD の自動再送キュー
│   │   ├── mdns_discovery_service.dart  # mDNS 公開 / 探索(bonsoir)
│   │   ├── discovery_service.dart       # ビーコン送受信 + Hub 喪失検出
│   │   ├── hub_background_keeper.dart   # Hub の FGS / AVAudioSession 制御
│   │   ├── pcm_constants.dart        # 48kHz/ステレオ/20ms 定数 + RMS 計算
│   │   ├── pcm_chunker.dart          # 任意サイズ → 20ms フレーム整流
│   │   ├── screen_audio_capture_service.dart # OS 別キャプチャの共通ファサード
│   │   ├── windows_loopback_service.dart     # Windows WASAPI loopback FFI
│   │   ├── opus_encoder_service.dart         # PCM16 → Opus
│   │   ├── opus_decoder_service.dart         # Opus → float32 PCM(PLC 対応)
│   │   ├── jitter_buffer.dart                # 順序復元 + 自動再同期 + LAN/WAN プリセット
│   │   ├── udp_sender_service.dart           # UDP 送信 + 再接続 + CMD 受信 / 送信ゲート
│   │   ├── udp_receiver_service.dart         # UDP 受信 + 再 bind + PONG / CMD 送信
│   │   └── audio_mixer_service.dart          # FFI(miniaudio ミキサー)+ VU レベル
│   ├── screens/
│   │   ├── setup_screen.dart         # ロール選択
│   │   ├── hub_screen.dart           # クライアント一覧 + マスター音量 + 設定
│   │   └── client_screen.dart        # 配信 UI + 手動接続 + 一時停止バナー
│   └── widgets/
│       ├── broadcast_picker_button.dart      # iOS の RPSystemBroadcastPickerView
│       ├── client_tile.dart                  # 1 クライアントの行 UI(音量 / ⏸▶ / 削除)
│       ├── vu_meter.dart                     # VU メーター描画
│       └── connection_status_badge.dart      # 接続状態バッジ
│
├── ios/Runner/                       # AppDelegate(hubPlayback チャネル)ほか
├── ios/BroadcastExtension/           # Xcode で別ターゲットとして手動追加
├── macos/Runner/                     # ScreenCaptureKitPlugin ほか
├── android/app/src/main/kotlin/.../
│   ├── MainActivity.kt               # MediaProjection + Hub/配信サービス起動
│   ├── AudioBroadcastService.kt      # 配信用 FGS(mediaProjection)
│   └── HubPlaybackService.kt         # Hub 用 FGS(mediaPlayback)
│
├── test/                             # ユニットテスト(131 件)
└── .github/workflows/                # CI/CD
```

---

## ビルド方法

### Windows

```bash
flutter build windows --release
# 出力: build/windows/x64/runner/Release/
#   local_audio_sync.exe
#   audio_mixer_plugin.dll   ← miniaudio ミキサー + WASAPI loopback(FFI プラグイン)
#   flutter_windows.dll
```

### Android

```bash
flutter build apk --release
# 出力: build/app/outputs/flutter-apk/app-release.apk
# (libaudio_mixer_plugin.so が全 ABI に同梱される)
```

### iOS(コードサイン不要のビルド確認)

```bash
flutter build ios --release --no-codesign
```

### macOS

```bash
flutter build macos --release
```

---

## テスト

### ユニットテスト

```bash
flutter test
# 131 件すべてパス
```

主要テスト群:

| テストファイル | 内容 |
| --- | --- |
| `control_messages_test.dart` | HELLO/HELLO2/CMD/CMDACK/PONG のパースと互換性 |
| `hub_controller_test.dart` | 接続ライフサイクル、設定復元、リモート制御、プリセット |
| `udp_sender_service_test.dart` | HELLO 接続、RESYNC、CMD 送信ゲート、PONG 監視 |
| `command_retry_queue_test.dart` | CMD 再送・ACK 停止・諦め |
| `device_identity_service_test.dart` | 永続 UUID の生成と再利用 |
| `client_settings_store_test.dart` | 音量設定の保存 / 復元 |
| `manual_hub_store_test.dart` | 手動接続履歴 |
| `jitter_buffer_test.dart` | 順序復元、PLC、自動再同期、32bit ラップ |
| `discovery_service_test.dart` | ビーコン v1/v2 パース、Hub 喪失タイムアウト |
| そのほか | pcm_chunker / pcm_constants / windows_loopback / audio_packet / hub_state |

### 静的解析

```bash
flutter analyze
# No issues found.
```

---

## CI/CD

GitHub Actions で以下のワークフローを自動実行します:

| ワークフロー | トリガー | 内容 |
| --- | --- | --- |
| `ci.yml` | 全ブランチの push / PR | `flutter analyze` + `flutter test --coverage` |
| `build-android.yml` | `main` / `develop` push | APK ビルド → Artifacts |
| `build-windows.yml` | `main` / `develop` push | EXE + DLL ビルド → Artifacts |
| `build-ios.yml` | `main` / `develop` push | コンパイル確認(署名なし) |
| `build-macos.yml` | `main` / `develop` push | macOS 13+ runner で macOS アプリビルド |

### iOS / iPadOS を実機でテストする方法

CI はコンパイル確認のみ。実機インストールは以下:

#### 方法 1 — Mac + USB(無料)

iPhone を Mac に USB 接続し、プロジェクトディレクトリで:

```bash
flutter devices
flutter run -d <device-id>
```

Xcode が自動で開発証明書を作成します(7 日間有効、無料 Apple ID で OK)。

#### 方法 2 — AltStore / Sideloadly(Windows / Mac、無料)

CI の Artifacts からダウンロードした IPA を、無料 Apple ID でサイドロード可能:

| ツール | OS | 特徴 |
| --- | --- | --- |
| [AltStore](https://altstore.io/) | Win/Mac | PC と同一 Wi-Fi で自動再署名 |
| [Sideloadly](https://sideloadly.io/) | Win/Mac | USB 接続で簡単インストール |

7 日ごとに再署名が必要(AltStore は自動更新可)。

### ブランチ戦略

```text
main       ← リリースブランチ(PR 必須、CI 必須)
develop    ← 開発統合ブランチ
feature/*  ← 機能開発
fix/*      ← バグ修正
```

---

## トラブルシューティング

### Hub が見つからない(クライアント側)

- Hub と Client が **同一 Wi-Fi** か確認
- Windows ファイアウォールで UDP **9999** および **7777** の受信許可
  - コントロールパネル → Windows Defender ファイアウォール → 受信の規則 → 新しい規則
- Android で UDP ブロードキャストが届かない場合、ルーターの **AP 分離(AP Isolation)** を無効化
- mDNS(Bonjour)がブロックされるネットワークもあります。その場合も上記ビーコンか、最終手段として**手動 IP 接続**(クライアント画面右上)を使ってください
- 6 秒間ビーコンを受信できないと「喪失」と判定して自動的に再探索に戻ります

### iOS を Hub にしたのにクライアントから見つからない

- iOS Hub は mDNS(Bonjour)でのみ発見されます(OS 制約でブロードキャスト送信不可)
- ルーターがマルチキャスト(mDNS)を通すか確認。ダメなら **手動 IP 接続** を使用
- ローカルネットワーク権限(設定 → プライバシー → ローカルネットワーク)を許可

### iOS で「ブロードキャスト開始」を押しても音が来ない

- App Group の設定がメインアプリと Extension で一致しているか確認(`group.com.example.local_audio_sync`)
- 一度アプリを完全にアンインストールしてから再インストール
- DRM 保護コンテンツ(Apple Music / Netflix 等)は仕様上取得できません
- 詳細は [docs/iOS_BROADCAST_SETUP.md のトラブルシューティング](docs/iOS_BROADCAST_SETUP.md#トラブルシューティング)参照

### macOS で音が取れない

- 「画面録画」許可が与えられているか:
  - システム設定 → プライバシーとセキュリティ → 画面録画 → local_audio_sync をオン
- macOS 13 未満では動作しません

### Windows で `loopback_start 失敗` エラー

- デフォルト出力デバイスが正しく設定されているか確認(タスクバー右下のスピーカーアイコン)
- 出力デバイスがビット深度や周波数を変えて拒否することがある場合は、デバイスのプロパティで「24bit / 48000Hz」設定にする

### 音声が出ない(Hub 側)

- 既定の **再生デバイス** が正しく設定されているか確認
- Android / iOS Hub では音量ボタンでメディア音量が下がっていないか確認
- リモート制御で **一時停止中** になっていないか(タイルのバッジを確認)

### 配信が途中で止まる

- iOS でメインアプリを完全終了(スワイプで閉じる)すると配信も止まります。アプリは起動したままにしてください
- Android でバッテリー最適化が有効だとバックグラウンドで停止することがあります:
  - 設定 → アプリ → local-audio-sync → バッテリー → 最適化しない
- Android を Hub にする場合も同様にバッテリー最適化を無効にしてください(mediaPlayback 通知が出ていれば維持されます)

### WAN / VPN 経由で音がブツブツ切れる

- Hub 設定(⚙)で受信バッファを **「WAN / VPN(安定重視)」** に切替(遅延約 200ms と引き換えに安定)

### `flutter build windows` が失敗する

Visual Studio Build Tools(C++ ワークロード)が必要です。

<https://visualstudio.microsoft.com/ja/downloads/#build-tools-for-visual-studio-2022>

---

## 依存ライブラリ

| パッケージ | バージョン | 用途 |
| --- | --- | --- |
| `flutter_riverpod` | ^2.6.1 | 状態管理 |
| `go_router` | ^14.6.2 | 画面遷移 |
| `opus_dart` | ^3.0.1 | Opus エンコード / デコード(FFI) |
| `opus_flutter` | ^3.0.1 | Opus ライブラリのロード |
| `bonsoir` | ^7.1.4 | mDNS / Bonjour(Hub 公開・探索) |
| `network_info_plus` | ^6.0.1 | ローカル IP 取得 |
| `uuid` | ^4.5.1 | 永続デバイス ID |
| `shared_preferences` | ^2.3.3 | ロール / デバイス ID / 音量設定の永続化 |
| `ffi` | ^2.1.0 | ネイティブミキサー呼び出し |
| `audio_mixer_ffi`(ローカル) | - | miniaudio ミキサー + WASAPI loopback(全 OS) |

---

## ライセンス

MIT License
