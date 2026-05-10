# local-audio-sync

ローカルネットワーク(LAN)上の **複数デバイスで再生されている内部音声**(他アプリの音 = Spotify / YouTube / ゲーム等)を、Wi-Fi 経由で 1 台の **Hub** に集約してまとめて再生するアプリです。

iPhone / iPad / macOS / Windows / Android がクライアントとして動作し、それぞれの OS のネイティブ API で内部音声をキャプチャし、Opus で圧縮した音声を UDP で Windows ハブへ送信します。

> **マイク機能は廃止しました**(2026-05-10)。集めるのは「他アプリの音」だけです。
> 詳細は [docs/PLAN.md](docs/PLAN.md) を参照。

---

## 目次

1. [できること / できないこと](#できること--できないこと)
2. [全体アーキテクチャ](#全体アーキテクチャ)
3. [動作要件](#動作要件)
4. [セットアップ手順](#セットアップ手順)
5. [使い方](#使い方)
6. [プラットフォーム別の内部音声キャプチャ詳細](#プラットフォーム別の内部音声キャプチャ詳細)
7. [通信プロトコル詳細](#通信プロトコル詳細)
8. [プロジェクト構造](#プロジェクト構造)
9. [ビルド方法](#ビルド方法)
10. [テスト](#テスト)
11. [CI/CD](#cicd)
12. [トラブルシューティング](#トラブルシューティング)

---

## できること / できないこと

### できること

- iPhone / iPad / macOS / Windows / Android で再生している **他アプリの音声** を取得
- LAN 内の Hub(Windows)に集約して再生
- 各クライアントごとに音量調整 / ミュート
- 自動探索(Hub のビーコンをクライアントが検出)
- Hub 喪失時の自動再探索、UDP ソケット死亡時の自動再生成
- 同期ずれ時の自動再同期(JitterBuffer 内蔵)

### できないこと

| 制限 | 理由 |
| --- | --- |
| マイクの音声を送る | 用途を内部音声に絞ったため(2026-05-10 仕様確定) |
| Apple Music / Netflix / Amazon Prime Video など DRM 保護コンテンツの音声を取得 | iOS / Android / macOS の OS 仕様で取得不可 |
| インターネット越し配信 | LAN 限定設計(NAT 越え非対応) |
| Hub を Windows 以外で動かす | miniaudio ベースの C++ ミキサーが現状 Windows ビルド対象 |

---

## 全体アーキテクチャ

```text
┌──────────────────────────────────────────────────────────────────┐
│  クライアント(送信側)                                            │
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
└──────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  Hub(Windows)                                                   │
│                                                                  │
│  UDP 受信 → クライアントごとのジッターバッファ(再同期つき)        │
│  → Opus デコード(PLC 対応)                                       │
│  → 個別音量調整                                                   │
│  → miniaudio ミキサー(C++ FFI)                                  │
│  → スピーカー出力                                                 │
└──────────────────────────────────────────────────────────────────┘
```

### 自動検出(ディスカバリー)

- Hub が UDP ブロードキャスト(ポート **9999**)で 2 秒ごとにビーコンを送信
- クライアントはビーコンを受信したら自動で Hub に接続を開始
- **6 秒間ビーコン未受信** → 「Hub 喪失」と判定 → 自動的に再探索状態へ復帰
- **UDP 送信失敗** → ソケット再生成 + 指数バックオフ再接続(最大 5 秒間隔)

---

## 動作要件

| プラットフォーム | バージョン要件 | 備考 |
| --- | --- | --- |
| Windows(Hub) | Windows 10 以降(x64) | Visual Studio 2022 Build Tools |
| Windows(Client) | Windows 10 以降(x64) | WASAPI loopback |
| iOS | iOS 14 以降 | Broadcast Upload Extension が必要 |
| iPadOS | iPadOS 14 以降 | Broadcast Upload Extension が必要 |
| macOS | **macOS 13 以降**(ScreenCaptureKit 要件) | 画面録画許可が必要 |
| Android | API 29(Android 10)以降 | MediaProjection 要件 |
| Flutter SDK | 3.24 以降 | |
| Dart SDK | 3.5 以降 | |

**全デバイスが同一 LAN(Wi-Fi / 有線)に接続している必要があります。**

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

iOS / iPadOS で他アプリの音を取るには、Xcode 上で **Broadcast Upload Extension ターゲット** を手動で追加する必要があります。詳細手順は別ドキュメントに記載しています。

→ [docs/iOS_BROADCAST_SETUP.md](docs/iOS_BROADCAST_SETUP.md)

### 4. macOS の追加セットアップ

初回起動時に「画面録画」の許可ダイアログが OS から表示されます。許可してください。

```text
システム設定 → プライバシーとセキュリティ → 画面録画 → local_audio_sync をオン
```

### 5. Windows のビルド準備(初回のみ)

Visual Studio 2022 Build Tools(C++ ワークロード)が必要です。

<https://visualstudio.microsoft.com/ja/downloads/#build-tools-for-visual-studio-2022>

### 6. Android の追加セットアップ

設定済みの `AndroidManifest.xml` でパーミッションが宣言されています。初回起動時に「画面のキャストとオーディオの記録」許可ダイアログが出るので許可してください。

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

1. アプリ起動 → 初期画面で **「Hub(集約・再生)」** を選択
2. デバイス名を入力して **「Hub として起動」** をタップ
3. Hub 画面に切り替わり、ビーコン送信が始まります
4. クライアントが接続すると一覧に表示されます
5. 各クライアントの **音量スライダー** / **ミュートボタン** で個別調整

### クライアント(送信側)の使い方

1. アプリ起動 → 初期画面で **「クライアント(送信)」** を選択
2. デバイス名を入力して **「クライアントとして起動」** をタップ
3. LAN 上の Hub を自動検索(ビーコン受信)
4. Hub が見つかると自動接続
5. **配信開始**:
   - **iOS / iPadOS**: 画面の **「タップして配信開始」** ボタンをタップ → システムシートで「Local Audio Sync 配信」を選択 → **ブロードキャストを開始**
   - **Android**: 画面のキャプチャ許可ダイアログが出るので許可
   - **macOS**: 自動でキャプチャ開始(画面録画許可は事前に承認しておく)
   - **Windows**: 自動でキャプチャ開始(デフォルト出力デバイスをループバック)
6. 配信中は VU メーターが反応します
7. 「Hub から切断」ボタンで停止

### 役割の切り替え

画面右上の **「⇄」** アイコンで役割選択画面に戻ります。選択したロールは次回起動時も保持されます。

---

## プラットフォーム別の内部音声キャプチャ詳細

| OS | 取得 API | 制約 |
| --- | --- | --- |
| **iOS / iPadOS** | Broadcast Upload Extension(ReplayKit) | DRM 不可、Extension メモリ 50MB、Picker UX 必須 |
| **Android** | MediaProjection + AudioPlaybackCaptureConfiguration(API 29+) | DRM 不可、対象アプリが `allowAudioPlaybackCapture` 許可必須 |
| **macOS** | ScreenCaptureKit + SCStream(macOS 13+) | 画面録画許可必須 |
| **Windows** | WASAPI loopback(`audio_mixer_plugin.dll` 経由) | デフォルト出力デバイスから取得 |

### iOS / iPadOS の詳細

- メインアプリ ↔ Extension 間は App Group コンテナ内の **UNIX Domain Socket(SOCK_DGRAM)** で PCM を転送
- Extension の 50MB メモリ制限を守るため、**エンコードや UDP 送信は Extension 側で行わず、メインアプリ側に集約**
- Extension の bundle ID(既定:`com.example.localAudioSync.BroadcastExtension`)はメインアプリ側の `client_screen.dart` で参照しているので、Xcode で Bundle ID を変えた場合は `_broadcastExtensionBundleId` 定数も更新

### Windows の詳細

- `audio_mixer_plugin.dll` 内の loopback API を Dart から FFI で叩く
- `loopback_start` → リングバッファに PCM16 を書き込み、Dart 側が 20ms 周期で polling
- Hub と同居する 1 つの DLL なので、Windows では **Hub と Client 兼務が可能**

---

## 通信プロトコル詳細

### ビーコン(UDP ブロードキャスト、ポート 9999)

Hub が 2 秒ごとに `255.255.255.255` へ送信するテキスト:

```text
LAHUB:{hubIPv4}:7777:{hubName}
例: LAHUB:192.168.1.10:7777:MyHub
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
| HELLO | Client → Hub | `HELLO:{name}:{uuid}` | 接続開始 |
| ACKHELLO | Hub → Client | `ACKHELLO:{assignedId}` | ID 割り当て |
| PING | Client → Hub | `PING:{clientId}` | 接続維持(5 秒ごと) |
| BYE | Client → Hub | `BYE:{clientId}` | 切断通知 |

### 音声仕様

| 項目 | 値 |
| --- | --- |
| コーデック | Opus |
| サンプルレート | 48,000 Hz |
| チャンネル | 2(ステレオ) |
| ビットレート | 128 kbps |
| フレームサイズ | 20 ms(960 サンプル/チャンネル、3840 byte の PCM16) |
| ジッターバッファ | 固定遅延方式 + **シーケンス乖離 100 フレーム以上で自動再同期** |

---

## プロジェクト構造

```text
local-audio-sync/
├── docs/
│   ├── PLAN.md                       # リアーキテクチャ計画
│   └── iOS_BROADCAST_SETUP.md        # iOS Extension の Xcode セットアップ手順
│
├── lib/
│   ├── main.dart                     # エントリポイント(Opus 初期化 + ProviderScope)
│   ├── app.dart                      # GoRouter ルーティング + ja_JP ロケール
│   ├── models/
│   │   ├── app_mode.dart             # enum AppMode { hub, client }
│   │   ├── client_info.dart          # クライアント情報(IP / 音量 / 状態)
│   │   └── audio_packet.dart         # UDP パケットのシリアライザ
│   ├── providers/
│   │   ├── app_mode_provider.dart    # ロール状態(SharedPreferences で永続化)
│   │   ├── hub_state_provider.dart   # 接続クライアント一覧 + 音量
│   │   └── client_state_provider.dart # 接続状態 / VU レベル
│   ├── services/
│   │   ├── pcm_constants.dart        # 48kHz/ステレオ/20ms 定数 + RMS 計算
│   │   ├── pcm_chunker.dart          # 任意サイズ → 20ms フレーム整流
│   │   ├── screen_audio_capture_service.dart # OS 別キャプチャの共通ファサード
│   │   ├── windows_loopback_service.dart     # Windows WASAPI loopback FFI
│   │   ├── opus_encoder_service.dart         # PCM16 → Opus
│   │   ├── opus_decoder_service.dart         # Opus → float32 PCM(PLC 対応)
│   │   ├── discovery_service.dart            # ビーコン送受信 + Hub 喪失検出
│   │   ├── jitter_buffer.dart                # 順序復元 + 自動再同期
│   │   ├── udp_sender_service.dart           # UDP 送信 + 自動再接続
│   │   ├── udp_receiver_service.dart         # UDP 受信 + 自動再 bind
│   │   └── audio_mixer_service.dart          # FFI(Windows ミキサー)
│   ├── screens/
│   │   ├── setup_screen.dart         # ロール選択(日本語)
│   │   ├── hub_screen.dart           # クライアント一覧(日本語)
│   │   └── client_screen.dart        # 配信開始 UI(日本語)
│   └── widgets/
│       ├── broadcast_picker_button.dart      # iOS の RPSystemBroadcastPickerView
│       ├── client_tile.dart                  # 1 クライアントの行 UI
│       ├── vu_meter.dart                     # VU メーター描画
│       └── connection_status_badge.dart      # 接続状態バッジ
│
├── ios/
│   ├── Runner/
│   │   ├── AppDelegate.swift                 # プラグイン登録のみに集約
│   │   ├── AudioSessionManager.swift         # AVAudioSession 一元管理
│   │   ├── BroadcastReceiverPlugin.swift     # UDS 受信 → EventChannel
│   │   ├── BroadcastPickerView.swift         # RPSystemBroadcastPickerView を埋め込む PlatformView
│   │   ├── Info.plist                        # 画面録画/ローカルネット の Usage Description
│   │   └── Runner.entitlements               # App Group
│   └── BroadcastExtension/                   # Xcode で別ターゲットとして手動追加(docs/iOS_BROADCAST_SETUP.md)
│       ├── SampleHandler.swift               # PCM 変換 + UDS 送信
│       ├── Info.plist
│       └── BroadcastExtension.entitlements
│
├── macos/Runner/
│   ├── ScreenCaptureKitPlugin.swift          # SCStream + capturesAudio
│   ├── DebugProfile.entitlements
│   └── Release.entitlements
│
├── android/app/src/main/
│   ├── AndroidManifest.xml                   # MediaProjection 関連パーミッション
│   └── kotlin/.../
│       ├── MainActivity.kt                   # MediaProjection + AudioPlaybackCapture
│       └── AudioBroadcastService.kt          # フォアグラウンドサービス(日本語通知)
│
├── windows/audio_mixer_plugin/
│   ├── audio_mixer.h / audio_mixer.cpp       # Hub ミキサー + Loopback API
│   ├── miniaudio.h
│   └── CMakeLists.txt
│
├── test/                                     # ユニットテスト(48 件)
│   ├── models/audio_packet_test.dart
│   ├── services/discovery_service_test.dart
│   ├── services/jitter_buffer_test.dart       # 再同期 5 件含む
│   ├── services/pcm_chunker_test.dart         # 9 件
│   ├── services/pcm_constants_test.dart       # 6 件
│   ├── services/windows_loopback_service_test.dart # 4 件
│   └── providers/hub_state_provider_test.dart
│
└── .github/workflows/                        # CI/CD
```

---

## ビルド方法

### Windows

```bash
flutter build windows --release
# 出力: build/windows/x64/runner/Release/
#   local_audio_sync.exe
#   audio_mixer_plugin.dll   ← miniaudio ベースのミキサー + WASAPI loopback
#   flutter_windows.dll
```

### Android

```bash
flutter build apk --release
# 出力: build/app/outputs/flutter-apk/app-release.apk
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
# 48 件すべてパス
```

主要テスト群:

| テストファイル | 件数 | 内容 |
| --- | --- | --- |
| `audio_packet_test.dart` | 6 | バイナリシリアライズ、シーケンスラップアラウンド |
| `jitter_buffer_test.dart` | 10 | 順序復元、PLC、自動再同期、32bit ラップ |
| `discovery_service_test.dart` | 9 | ビーコンパース、Hub 喪失タイムアウト |
| `pcm_chunker_test.dart` | 9 | 任意サイズ入力の 20ms フレーム整流 |
| `pcm_constants_test.dart` | 6 | RMS 計算、定数の一貫性 |
| `windows_loopback_service_test.dart` | 4 | DLL ロード失敗時のフォールバック |
| `hub_state_provider_test.dart` | 4 | クライアント追加 / 削除 / 音量 / ミュート |

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
- 6 秒間ビーコンを受信できないと「喪失」と判定して自動的に再探索に戻ります

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

- Windows の既定の **再生デバイス** が正しく設定されているか確認
- タスクマネージャーで `audio_mixer_plugin.dll` がロードされているか確認

### 配信が途中で止まる

- iOS でメインアプリを完全終了(スワイプで閉じる)すると配信も止まります。アプリは起動したままにしてください
- Android でバッテリー最適化が有効だとバックグラウンドで停止することがあります:
  - 設定 → アプリ → local-audio-sync → バッテリー → 最適化しない

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
| `network_info_plus` | ^6.0.1 | ローカル IP 取得 |
| `uuid` | ^4.5.1 | クライアント UUID |
| `shared_preferences` | ^2.3.3 | ロール永続化 |
| `ffi` | ^2.1.0 | Windows DLL 呼び出し |
| `miniaudio.h` | latest | Windows オーディオ出力 + WASAPI loopback |

---

## ライセンス

MIT License
